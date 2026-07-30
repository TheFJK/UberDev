SPEC_WRITE_RETRY_INPUTS="$(uberdev_child_inputs_build orchestrator.spec.write \
  issue_path "$(uberdev_design_json_string "$issue_body_path")" \
  research_paths "$research_paths_json" \
  questions_path "$(uberdev_design_json_string "$qa_answers_path")" \
  working_dir "$(uberdev_design_json_string "$WORKING_DIR_ABS")" \
  summary_path "$(uberdev_design_json_string "$spec_summary_path")" \
  verification_feedback_path "$(uberdev_design_json_string "$verification_feedback_path")")"
uberdev_design_dispatch orchestrator.spec.write orchestrator-spec-write-a2 spec-writer spec run 'null' "$SPEC_WRITE_RETRY_INPUTS"
uberdev_design_wait orchestrator-spec-write-a2 600
