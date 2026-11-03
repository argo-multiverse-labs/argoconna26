# Rung-3 safe-fix policy: may the agent's fix PR auto-merge?
#
# Input is the JSON from policy/facts/facts.py (Git facts only). Data is
# policy/data/agent.yaml (agent_login). Auto-merge is allowed only when
# deny is empty, so every rule is written as "deny unless proven OK":
# a missing or mistyped fact denies, it never passes.
#
#   conftest test facts.json -p policy --namespace autofix -d policy/data
package autofix

config_path := `^apps/([^/]+)/config/.+`

forbidden_kinds := ["image", "rbac", "crd", "application"]

# Rule 1: exactly two changes, one key in a file under apps/*/config/ and the
# config-version annotation on that app's pod template.
deny contains "rule 1: change one config key under apps/<app>/config/ and that app's config-version, nothing else" if {
	not rule1_ok
}

rule1_ok if {
	count(input.changed_files) == 2
	count(input.config_changes) == 1
	change := input.config_changes[0]
	is_string(change.key)
	not startswith(change.key, "/")
	app := regex.find_all_string_submatch_n(config_path, change.file, 1)[0][1]
	workload := input.rollout_changes.file
	startswith(workload, concat("", ["apps/", app, "/"]))
	is_object(input.rollout_changes.config_version)
	{f | some f in input.changed_files} == {change.file, workload}
}

# Rule 2: the config-version change is an increment by exactly one.
deny contains "rule 2: config-version must go up by exactly one" if {
	not rule2_ok
}

rule2_ok if {
	cv := input.rollout_changes.config_version
	is_version(cv.from)
	is_version(cv.to)
	to_number(cv.to) == to_number(cv.from) + 1
}

is_version(v) if {
	is_string(v)
	regex.match(`^[0-9]{1,9}$`, v)
}

# Rule 3: the new value already existed for that key at an earlier commit on
# the tracked branch.
deny contains "rule 3: the new value was never used on the tracked branch" if {
	not input.to_value_seen_before == true
}

# Rule 4: no image, RBAC, CRD or Application changes, and nothing in the
# Rollout except the annotation.
deny contains msg if {
	not rule4_ok
	msg := sprintf("rule 4: forbidden change (%s)", [concat(", ", rule4_found)])
}

rule4_ok if {
	every kind in forbidden_kinds {
		input.forbidden_changes[kind] == false
	}
	input.rollout_changes.other_changes == false
}

rule4_found contains kind if {
	some kind in forbidden_kinds
	not input.forbidden_changes[kind] == false
}

rule4_found contains "rollout" if {
	not input.rollout_changes.other_changes == false
}

# Rule 5: the PR body cites the cause commit, that SHA is on the tracked
# branch, and it changed the same key.
deny contains "rule 5: the cited cause commit must be on the tracked branch and have changed this key" if {
	not rule5_ok
}

rule5_ok if {
	is_string(input.cited_sha)
	regex.match(`^[0-9a-f]{40}$`, input.cited_sha)
	input.cited_sha_on_branch == true
	input.cited_sha_changed_key == true
}

# Rule 6: the PR author is the agent's GitHub App.
deny contains "rule 6: the PR author must be the agent's GitHub App" if {
	not rule6_ok
}

rule6_ok if {
	is_string(data.agent_login)
	data.agent_login != ""
	input.author.login == data.agent_login
	input.author.type == "Bot"
}
