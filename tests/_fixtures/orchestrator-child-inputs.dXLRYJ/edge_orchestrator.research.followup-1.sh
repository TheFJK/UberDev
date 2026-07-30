FOLLOWUP_INPUTS="$(uberdev_child_inputs_build orchestrator.research.followup \
  working_dir "$(uberdev_design_json_string "$WORKING_DIR_ABS")" \
  summary_path "$(uberdev_design_json_string "$followup_summary_path")" \
  question "$(uberdev_design_json_string "$scope_shift_question")" \
  answer "$(uberdev_design_json_string "$scope_shift_answer")")"
uberdev_design_dispatch orchestrator.research.followup orchestrator-research-followup-a1 research-codebase research none '[]' "$FOLLOWUP_INPUTS"
uberdev_design_wait orchestrator-research-followup-a1 300
