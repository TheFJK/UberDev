GENERAL_CONSTRAINTS_INPUTS="$(uberdev_child_inputs_build orchestrator.research.constraints \
  issue_path "$(uberdev_design_json_string "$issue_body_path")" \
  working_dir "$(uberdev_design_json_string "$WORKING_DIR_ABS")" \
  summary_path "$(uberdev_design_json_string "$research_constraints_summary_path")")"
uberdev_design_dispatch orchestrator.research.constraints orchestrator-research-constraints-a1 research-constraints research none '[]' "$GENERAL_CONSTRAINTS_INPUTS"
