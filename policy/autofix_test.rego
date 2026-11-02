package autofix_test

import data.autofix

# Tests for the rung-3 auto-fix policy: one pass and one deny per rule,
# plus fail-closed checks. Run with: conftest verify --policy policy

agent := "argoconna26-agent[bot]"

cause := "0123456789abcdef0123456789abcdef01234567"

config_file := "apps/checkout/config/checkout-config.yaml"

rollout_file := "apps/checkout/deploy/rollout.yaml"

# The facts facts.py prints for a correct two-line fix from the agent.
good := {
	"changed_files": [config_file, rollout_file],
	"config_changes": [{"file": config_file, "key": "UPSTREAM_TIMEOUT_MS", "from": "200", "to": "2000"}],
	"rollout_changes": {
		"file": rollout_file,
		"config_version": {"from": "7", "to": "8"},
		"other_changes": false,
	},
	"forbidden_changes": {"image": false, "rbac": false, "crd": false, "application": false},
	"to_value_seen_before": true,
	"cited_sha": cause,
	"cited_sha_on_branch": true,
	"cited_sha_changed_key": true,
	"author": {"login": agent, "type": "Bot"},
}

deny_for(facts) := msgs if {
	msgs := autofix.deny with input as facts with data.agent_login as agent
}

denied(facts, n) if {
	some msg in deny_for(facts)
	startswith(msg, sprintf("rule %d:", [n]))
}

test_good_fix_has_no_denies if {
	count(deny_for(good)) == 0
}

# --- Rule 1: exactly two changes ----------------------------------------------

test_rule1_exactly_two_changes_pass if {
	not denied(good, 1)
}

test_rule1_three_changes_deny if {
	facts := object.union(good, {"changed_files": [config_file, rollout_file, "README.md"]})
	denied(facts, 1)
}

test_rule1_two_config_keys_deny if {
	facts := object.union(good, {"config_changes": [
		{"file": config_file, "key": "UPSTREAM_TIMEOUT_MS", "from": "200", "to": "2000"},
		{"file": config_file, "key": "PRICING_URL", "from": "a", "to": "b"},
	]})
	denied(facts, 1)
}

test_rule1_non_data_config_change_deny if {
	facts := object.union(good, {"config_changes": [{"file": config_file, "key": "/metadata", "from": null, "to": null}]})
	denied(facts, 1)
}

test_rule1_config_outside_apps_config_deny if {
	other := "platform/litellm/config.yaml"
	facts := object.union(good, {
		"changed_files": [other, rollout_file],
		"config_changes": [{"file": other, "key": "UPSTREAM_TIMEOUT_MS", "from": "200", "to": "2000"}],
	})
	denied(facts, 1)
}

test_rule1_other_apps_rollout_deny if {
	pricing := "apps/pricing/deploy/deployment.yaml"
	facts := object.union(good, {
		"changed_files": [config_file, pricing],
		"rollout_changes": {"file": pricing, "config_version": {"from": "7", "to": "8"}, "other_changes": false},
	})
	denied(facts, 1)
}

test_rule1_missing_annotation_change_deny if {
	facts := object.union(good, {
		"changed_files": [config_file],
		"rollout_changes": {"file": null, "config_version": null, "other_changes": false},
	})
	denied(facts, 1)
}

# --- Rule 2: config-version +1 ------------------------------------------------

test_rule2_increment_by_one_pass if {
	not denied(good, 2)
}

test_rule2_increment_by_two_deny if {
	facts := object.union(good, {"rollout_changes": {"config_version": {"from": "7", "to": "9"}}})
	denied(facts, 2)
}

test_rule2_decrement_deny if {
	facts := object.union(good, {"rollout_changes": {"config_version": {"from": "8", "to": "7"}}})
	denied(facts, 2)
}

test_rule2_non_integer_deny if {
	facts := object.union(good, {"rollout_changes": {"config_version": {"from": "7", "to": "8.0"}}})
	denied(facts, 2)
}

# --- Rule 3: the new value was seen before on the tracked branch --------------

test_rule3_value_seen_before_pass if {
	not denied(good, 3)
}

test_rule3_value_seen_before_deny if {
	facts := object.union(good, {"to_value_seen_before": false})
	denied(facts, 3)
}

# --- Rule 4: nothing forbidden ------------------------------------------------

test_rule4_no_forbidden_pass if {
	not denied(good, 4)
}

test_rule4_image_change_deny if {
	facts := object.union(good, {"forbidden_changes": {"image": true}})
	denied(facts, 4)
}

test_rule4_each_forbidden_kind_deny if {
	every kind in ["image", "rbac", "crd", "application"] {
		denied(object.union(good, {"forbidden_changes": {kind: true}}), 4)
	}
}

test_rule4_other_rollout_change_deny if {
	facts := object.union(good, {"rollout_changes": {"other_changes": true}})
	denied(facts, 4)
}

# --- Rule 5: the cited cause is on the branch and changed the key -------------

test_rule5_cited_on_branch_and_key_pass if {
	not denied(good, 5)
}

test_rule5_cited_not_on_branch_deny if {
	facts := object.union(good, {"cited_sha_on_branch": false})
	denied(facts, 5)
}

test_rule5_cited_other_key_deny if {
	facts := object.union(good, {"cited_sha_changed_key": false})
	denied(facts, 5)
}

test_rule5_no_cited_sha_deny if {
	facts := object.union(good, {"cited_sha": null})
	denied(facts, 5)
}

# --- Rule 6: the author is the agent's GitHub App -----------------------------

test_rule6_author_is_agent_pass if {
	not denied(good, 6)
}

test_rule6_human_author_deny if {
	facts := object.union(good, {"author": {"login": "lukepatrick", "type": "User"}})
	denied(facts, 6)
}

test_rule6_bot_login_but_user_type_deny if {
	facts := object.union(good, {"author": {"type": "User"}})
	denied(facts, 6)
}

test_rule6_no_agent_login_configured_deny if {
	msgs := autofix.deny with input as good
	some msg in msgs
	startswith(msg, "rule 6:")
}

# --- Messages and failing closed ----------------------------------------------

test_deny_messages_name_rule_numbers if {
	msgs := deny_for({})
	every msg in msgs {
		regex.match(`^rule [1-6]: `, msg)
	}
	numbers := {n | some msg in msgs; n := substring(msg, 5, 1)}
	numbers == {"1", "2", "3", "4", "5", "6"}
}

test_wrong_types_fail_closed if {
	facts := object.union(good, {
		"to_value_seen_before": "true",
		"cited_sha_on_branch": 1,
		"forbidden_changes": {"image": "false"},
	})
	denied(facts, 3)
	denied(facts, 4)
	denied(facts, 5)
}
