"use strict";
// Markdown to HTML for what agents write: transcript text, plans, asks, rundowns. Everything is
// escaped before any markup is added, so text can never become HTML; links are http(s) only,
// plus, with md(text, { notes: true }) for a note on the Daily tab, `[[target|label]]` as an
// in-app `#daily/<target>` link and `#p:<name>` as `#projects/<name>` and any other `#tag` as a tag chip, with HTML comments dropped.
// With { notes: true, ack: true } (the inbox page only), a task item ending `<!-- ack:<key> -->`
// gets a live checkbox carrying `data-ack="<key>"`; every other checkbox stays disabled.
// Covers what Claude writes (headings, lists, task lists, code, tables, quotes, emphasis), not
// all of CommonMark. Newlines inside a paragraph are kept as line breaks, as in a chat.
// Unit tests: tests/agent-web/md.test.mjs.

const md = (() => {
  // Its own copy of ui.js's esc, so the file also loads alone under node for its tests.
  const ESC = { "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" };
  const escape = (s) => String(s).replace(/[&<>"']/g, (c) => ESC[c]);

  const FENCE = /^ {0,3}(`{3,}|~{3,})\s*([\w+#.-]*)/;
  const HEADING = /^ {0,3}(#{1,6})\s+(.*?)\s*#*\s*$/;
  const RULE = /^ {0,3}([-*_])(\s*\1){2,}\s*$/;
  const QUOTE = /^ {0,3}>\s?/;
  const ITEM = /^(\s*)([-*+]|\d{1,9}[.)])\s+(.*)$/;
  const TABLE_SEP = /^\s*\|?\s*:?-+:?\s*(\|\s*:?-+:?\s*)*\|?\s*$/;

  // Set for the length of one md(text, { notes: true }) call.
  let notes = false, acks = false;
  // A tickable inbox row's key, kept through the comment strip: the ts of its ingest event.
  const ACK_KEY = "<!-- ack:([0-9T:.+Z-]{1,40}) -->";
  const ACK = new RegExp(`\\s*${ACK_KEY}\\s*$`), ACK_ONLY = new RegExp(`^${ACK_KEY}$`);
  // A vault-relative target as a URL fragment: each segment encoded, the slashes kept readable.
  const frag = (t) => t.trim().split("/").map(encodeURIComponent).join("/");
  const wikilink = (target, label) => `<a href="#daily/${escape(frag(target))}" class="wl">${escape((label || target).trim())}</a>`;
  const ptag = (name) => `<a href="#projects/${escape(encodeURIComponent(name))}" class="ptag">#p:${escape(name)}</a>`;

  const link = (url, label) => `<a href="${escape(url)}" target="_blank" rel="noopener noreferrer">${escape(label)}</a>`;

  // Inline markup on one run of text. Code spans and links are taken out as placeholders on
  // the raw text first, so emphasis never reaches inside them and a URL is matched before its
  // quotes become entities; the rest is escaped, then emphasised.
  function inline(text) {
    const held = [];
    const hold = (html) => `\u0000${held.push(html) - 1}\u0000`;
    let s = String(text).replace(/\u0000/g, "")
      .replace(/(`+)([^`]|[^`][\s\S]*?[^`])\1(?!`)/g, (m, ticks, code) => hold(`<code>${escape(code.trim() || code)}</code>`))
      .replace(/\[([^\]\n]+)\]\((https?:\/\/[^\s)]+)\)/g, (m, label, url) => hold(link(url, label)))
      .replace(/\bhttps?:\/\/[^\s<>"'`]*[^\s<>"'`.,;:!?)\]]/g, (url) => hold(link(url, url)));
    if (notes) {
      s = s.replace(/\[\[([^\]|#\n]+)(?:#[^\]|\n]*)?(?:\|([^\]\n]+))?\]\]/g, (m, t, label) => hold(wikilink(t, label)))
        .replace(/(^|[\s(])#p:([\w.-]+)/g, (m, pre, name) => pre + hold(ptag(name)))
        .replace(/(^|[\s(])#([A-Za-z][\w/-]*)(?![\w:])/g, (m, pre, tag) => pre + hold(`<span class="ntag">#${escape(tag)}</span>`));
    }
    s = escape(s)
      .replace(/\*\*(?=\S)([\s\S]*?\S)\*\*/g, "<strong>$1</strong>")
      .replace(/(^|[^\w])__(?=\S)([\s\S]*?\S)__(?!\w)/g, "$1<strong>$2</strong>")
      .replace(/(^|[^*\w])\*(?=[^\s*])([^*\n]*?[^\s*])\*(?![*\w])/g, "$1<em>$2</em>")
      .replace(/(^|[^\w])_(?=[^\s_])([^_\n]*?[^\s_])_(?!\w)/g, "$1<em>$2</em>")
      .replace(/~~(?=\S)([^~\n]*?\S)~~/g, "<del>$1</del>");
    return s.replace(/\u0000(\d+)\u0000/g, (m, i) => held[+i]);
  }

  const cells = (line) => line.trim().replace(/^\|/, "").replace(/(^|[^\\])\|$/, "$1").split(/(?<!\\)\|/).map((c) => c.trim().replace(/\\\|/g, "|"));

  function table(head, sep, rows) {
    const align = cells(sep).map((c) => (c.startsWith(":") && c.endsWith(":") ? "center" : c.endsWith(":") ? "right" : ""));
    const td = (tag, c, i) => `<${tag}${align[i] ? ` style="text-align:${align[i]}"` : ""}>${inline(c)}</${tag}>`;
    const tr = (tag) => (row) => `<tr>${head.map((_, i) => td(tag, row[i] || "", i)).join("")}</tr>`;
    return `<div class="md-table"><table><thead>${tr("th")(head)}</thead><tbody>${rows.map(tr("td")).join("")}</tbody></table></div>`;
  }

  // A run of list items, nested by indent. Each item is [indent, ordered, start, text].
  function list(items) {
    let html = "";
    const open = []; // [{ indent, tag }]
    const close = () => { html += `</li></${open.pop().tag}>`; };
    for (const [indent, ordered, start, raw] of items) {
      while (open.length && indent < open[open.length - 1].indent) close();
      const top = open[open.length - 1];
      const tag = ordered ? "ol" : "ul";
      if (top && indent === top.indent && top.tag === tag) html += "</li>";
      else {
        if (top && indent === top.indent) close(); // same level, the other kind of list
        open.push({ indent, tag });
        html += `<${tag}${ordered && start !== 1 ? ` start="${start}"` : ""}>`;
      }
      const key = ACK.exec(raw), text = key ? raw.slice(0, key.index) : raw;
      const task = /^\[([ xX/])\]\s+(.*)$/.exec(text);
      const ack = acks && key && task && task[1] !== "/" ? key[1] : null;
      html += !task ? `<li>${inline(text)}`
        : task[1] === "/" ? `<li class="task doing"><input type="checkbox" disabled> <span class="cchip running">doing</span> ${inline(task[2])}`
        : `<li class="task${task[1] === " " ? "" : " done"}"><input type="checkbox"${ack ? ` data-ack="${escape(ack)}"` : " disabled"}${task[1] === " " ? "" : " checked"}> ${inline(task[2])}`;
    }
    while (open.length) close();
    return html;
  }

  function blocks(lines) {
    let html = "", i = 0, para = [];
    const flush = () => { if (para.length) html += `<p>${para.map(inline).join("<br>")}</p>`; para = []; };
    while (i < lines.length) {
      const line = lines[i];
      let m;
      if (!line.trim()) { flush(); i++; continue; }
      if ((m = FENCE.exec(line))) {
        flush();
        const close = new RegExp(`^ {0,3}${m[1][0]}{${m[1].length},}\\s*$`);
        const code = [];
        for (i++; i < lines.length && !close.test(lines[i]); i++) code.push(lines[i]);
        i++;
        html += `<pre class="md-code"${m[2] ? ` data-lang="${escape(m[2])}"` : ""}><code>${escape(code.join("\n"))}</code></pre>`;
        continue;
      }
      if ((m = HEADING.exec(line))) { flush(); html += `<h${m[1].length}>${inline(m[2])}</h${m[1].length}>`; i++; continue; }
      if (RULE.test(line)) { flush(); html += "<hr>"; i++; continue; }
      if (QUOTE.test(line)) {
        flush();
        const q = [];
        for (; i < lines.length && QUOTE.test(lines[i]); i++) q.push(lines[i].replace(QUOTE, ""));
        html += `<blockquote>${blocks(q)}</blockquote>`;
        continue;
      }
      if (line.includes("|") && i + 1 < lines.length && TABLE_SEP.test(lines[i + 1]) && lines[i + 1].includes("-")) {
        flush();
        const head = cells(line), sep = lines[i + 1], rows = [];
        for (i += 2; i < lines.length && lines[i].includes("|") && lines[i].trim(); i++) rows.push(cells(lines[i]));
        html += table(head, sep, rows);
        continue;
      }
      if ((m = ITEM.exec(line)) && !RULE.test(line)) {
        flush();
        const items = [];
        while (i < lines.length) {
          const it = ITEM.exec(lines[i]);
          if (it && !RULE.test(lines[i])) {
            const n = parseInt(it[2], 10);
            items.push([it[1].replace(/\t/g, "    ").length, !isNaN(n), isNaN(n) ? 1 : n, it[3]]);
            i++;
          } else if (lines[i].trim() && items.length && /^\s+\S/.test(lines[i]) && !FENCE.test(lines[i])) {
            items[items.length - 1][3] += "\n" + lines[i].trim(); // a wrapped item continues
            i++;
          } else break;
        }
        html += list(items);
        continue;
      }
      para.push(line);
      i++;
    }
    flush();
    return html;
  }

  return (text, opts) => {
    notes = !!(opts && opts.notes);
    acks = notes && !!opts.ack;
    try {
      let t = String(text == null ? "" : text).replace(/\r\n?/g, "\n");
      if (notes) t = t.replace(/<!--[\s\S]*?-->/g, (c) => (acks && ACK_ONLY.test(c) ? c : ""));
      return blocks(t.split("\n"));
    } finally { notes = false; acks = false; }
  };
})();

if (typeof module === "object" && module.exports) module.exports = { md };
