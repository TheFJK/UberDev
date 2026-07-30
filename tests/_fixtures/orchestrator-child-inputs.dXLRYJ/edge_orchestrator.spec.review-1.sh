SPEC_REVIEW_INPUTS="$(uberdev_child_inputs_build orchestrator.spec.review \
  spec_path "$(uberdev_design_json_string "$spec_path")" \
  issue_path "$(uberdev_design_json_string "$issue_body_path")" \
  research_paths "$research_paths_json" \
  working_dir "$(uberdev_design_json_string "$WORKING_DIR_ABS")")"
uberdev_design_dispatch orchestrator.spec.review orchestrator-spec-review-a1 spec-reviewer spec run 'null' "$SPEC_REVIEW_INPUTS"
uberdev_design_wait orchestrator-spec-review-a1 600
