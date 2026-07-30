GENERAL_PATTERNS_INPUTS="$(uberdev_child_inputs_build orchestrator.research.patterns \
  issue_path "$(uberdev_design_json_string "$issue_body_path")" \
  working_dir "$(uberdev_design_json_string "$WORKING_DIR_ABS")" \
  summary_path "$(uberdev_design_json_string "$research_patterns_summary_path")")"
uberdev_design_dispatch orchestrator.research.patterns orchestrator-research-patterns-a1 research-patterns research none '[]' "$GENERAL_PATTERNS_INPUTS"
