GENERAL_CODEBASE_INPUTS="$(uberdev_child_inputs_build orchestrator.research.codebase \
  issue_path "$(uberdev_design_json_string "$issue_body_path")" \
  working_dir "$(uberdev_design_json_string "$WORKING_DIR_ABS")" \
  summary_path "$(uberdev_design_json_string "$research_codebase_summary_path")")"
uberdev_design_dispatch orchestrator.research.codebase orchestrator-research-codebase-a1 research-codebase research none '[]' "$GENERAL_CODEBASE_INPUTS"
