#!/usr/bin/env perl
# intake_callers.pl <root>: the files under <root> that run `agent-queue add` or `notes ptask ... add`,
# one path a line, relative to <root>. tests/unit/queue_doc.bats holds each one to a row of
# QUEUE.md "Intake channels". A hit is a call, not text about one: a comment, a message in quotes
# and a hint with a <placeholder> argument are skipped, and so is notes-cli, which implements the writer.
use strict;
use warnings;
use File::Find;

my $root = shift or die "usage: intake_callers.pl <root>\n";
my @dirs = grep { -d "$root/$_" } qw(.local/bin .local/lib .local/src .claude/hooks .claude/skills .config/hunk);
my $skip_file = qr{\.(md|json|jsonl|conf|toml|example|tsv|ya?ml|pyc|lock|svg)$};
my $skip_dir  = qr{(^|/)(notes-cli|target|node_modules|__pycache__|\.git)(/|$)};
my $env  = qr/(?:[A-Za-z_]\w*=(?:"[^"]*"|'[^']*'|\S*)\s+)*/;
my $cmd  = qr/(?:agent-queue(?:\s+-\S+)*|"?\$AQ"?|_board|notes(?:\s+--profile\s+\S+)?\s+ptask|np\s+\S+|\$BENCH_NOTES_CMD|ptask)\b[^;&|#]*?(?<![-\w])add\b/;
my $sh   = qr/(?:^|[;&|({]|\$\(|\b(?:then|do|else)\b)\s*$env$cmd/;
my $argv = qr/"ptask"[^#]*"add"|argv\(&\["add"|"ptask", &w\.project|"agent-queue"\s*,\s*"add"/;

my %seen;
find({ no_chdir => 1, wanted => sub {
    my $f = $File::Find::name;
    return unless -f $f && !-l $f && $f !~ $skip_file && $f !~ $skip_dir;
    open(my $fh, '<', $f) or return;
    while (my $l = <$fh>) {
        next if $l =~ m{^\s*(?:#|//|\*|///)};
        next if $l =~ /<[a-z][a-z0-9 -]*>/;
        if ($l =~ $argv) { $seen{$f} = 1; last }
        while ($l =~ /($sh)/g) {
            if ($1 =~ /^\$\(/) { $seen{$f} = 1; last }
            my $pre = substr($l, 0, $-[1]);
            $pre =~ s/.*\$\(//;
            my $q = () = $pre =~ /(?<!\\)"/g;
            if ($q % 2 == 0) { $seen{$f} = 1; last }
        }
        last if $seen{$f};
    }
    close $fh;
} }, map { "$root/$_" } @dirs);
for (sort keys %seen) { s{^\Q$root\E/}{}; print "$_\n" }
