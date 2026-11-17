-- opencode's own DB, the two tables so_opencode_rows and item_oc_end read: one root session that spent tokens
-- and cost, whose last assistant message finished (stop), so it ended stopped.
CREATE TABLE session_v2 (id text, parent_id text, directory text, title text, model text, summary_files integer, cost real, tokens_input integer, tokens_output integer, tokens_reasoning integer, tokens_cache_read integer, tokens_cache_write integer, time_created integer, time_updated integer);
CREATE TABLE session_message (id text PRIMARY KEY, session_id text NOT NULL, type text NOT NULL, seq integer NOT NULL, time_created integer NOT NULL, time_updated integer NOT NULL, data text NOT NULL);
INSERT INTO session_v2 VALUES ('ses_contract', NULL, '/w/proj', 'fix the menu', '{"id":"litellm/reasoning","providerID":"litellm"}', 2, 0.042, 300, 60, 20, 100, 0, 1762689600000, 1762690200000);
INSERT INTO session_message VALUES ('m1', 'ses_contract', 'user', 1, 1762689600000, 1762689600000, '{"text":"fix the menu"}');
INSERT INTO session_message VALUES ('m2', 'ses_contract', 'assistant', 2, 1762689601000, 1762690200000, '{"finish":"stop"}');
