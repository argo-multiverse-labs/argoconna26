package goldenpath_test

import rego.v1

import data.goldenpath

labels := {
	"example.dev/owner": "payments-team",
	"example.dev/tier": "1",
	"slo.example.dev/success-rate": "99",
}

workload(kind, meta_labels, tmpl_labels) := {
	"apiVersion": "apps/v1",
	"kind": kind,
	"metadata": {"name": "x", "labels": meta_labels},
	"spec": {"template": {"metadata": {"labels": tmpl_labels}}},
}

test_good_passes if {
	count(goldenpath.deny) == 0 with input as workload("Rollout", labels, labels)
	count(goldenpath.deny) == 0 with input as workload("Deployment", labels, labels)
}

test_missing_owner_denied if {
	bad := object.remove(labels, ["example.dev/owner"])
	msgs := goldenpath.deny with input as workload("Deployment", bad, bad)
	some msg in msgs
	contains(msg, "example.dev/owner")
}

test_missing_slo_denied if {
	bad := object.remove(labels, ["slo.example.dev/success-rate"])
	msgs := goldenpath.deny with input as workload("Rollout", bad, bad)
	some msg in msgs
	contains(msg, "slo.example.dev/success-rate")
}

test_pod_template_labels_required if {
	# labels on the workload metadata alone are not enough
	msgs := goldenpath.deny with input as workload("Rollout", labels, {"app": "x"})
	some msg in msgs
	contains(msg, "pod template")
}

test_empty_label_value_denied if {
	bad := object.union(labels, {"example.dev/tier": ""})
	count(goldenpath.deny) > 0 with input as workload("Deployment", bad, bad)
}

test_other_kinds_ignored if {
	count(goldenpath.deny) == 0 with input as {"kind": "Service", "metadata": {"name": "x"}}
}
