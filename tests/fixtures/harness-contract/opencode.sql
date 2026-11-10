-- opencode's own DB, the two tables so_opencode_rows reads: one root session that spent tokens and cost.
CREATE TABLE session_v2 (id text, parent_id text, directory text, title text, model text, summary_files integer, cost real, tokens_input integer, tokens_output integer, tokens_reasoning integer, tokens_cache_read integer, tokens_cache_write integer, time_created integer, time_updated integer);
CREATE TABLE session_message (session_id text, type text, data text);
INSERT INTO session_v2 VALUES ('oc-contract', NULL, '/w/proj', 'fix the menu', '{"id":"litellm/reasoning","providerID":"litellm"}', 2, 0.042, 300, 60, 20, 100, 0, 1762689600000, 1762690200000);
