GENERAL_SECURITY_INPUTS="$(uberdev_child_inputs_build orchestrator.research.security \
  issue_path "$(uberdev_design_json_string "$issue_body_path")" \
  working_dir "$(uberdev_design_json_string "$WORKING_DIR_ABS")" \
  summary_path "$(uberdev_design_json_string "$research_security_summary_path")")"
uberdev_design_dispatch orchestrator.research.security orchestrator-research-security-a1 research-security research subtask "$validated_risk_signals_json" "$GENERAL_SECURITY_INPUTS"
