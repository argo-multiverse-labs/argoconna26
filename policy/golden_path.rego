# Golden path: every Deployment and Rollout carries the ownership and SLO labels,
# on the workload and on its pod template. Run with: conftest test --namespace goldenpath
package goldenpath

import rego.v1

required := [
	"example.dev/owner",
	"example.dev/tier",
	"slo.example.dev/success-rate",
]

workload_kinds := {"Deployment", "Rollout"}

has_label(labels, key) if {
	labels[key] != ""
}

deny contains msg if {
	input.kind in workload_kinds
	some key in required
	not has_label(object.get(input, ["metadata", "labels"], {}), key)
	msg := sprintf("%s %s: missing required label %s", [input.kind, input.metadata.name, key])
}

deny contains msg if {
	input.kind in workload_kinds
	some key in required
	not has_label(object.get(input, ["spec", "template", "metadata", "labels"], {}), key)
	msg := sprintf("%s %s: pod template is missing required label %s", [input.kind, input.metadata.name, key])
}
