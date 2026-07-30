SPEC_REVIEW_FORMAT_INPUTS="$(uberdev_child_inputs_format_retry orchestrator.spec.review "$SPEC_REVIEW_INPUTS" "$spec_review_format_example_path")"
uberdev_design_dispatch orchestrator.spec.review orchestrator-spec-review-a2 spec-reviewer spec run 'null' "$SPEC_REVIEW_FORMAT_INPUTS"
uberdev_design_wait orchestrator-spec-review-a2 600
