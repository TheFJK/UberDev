GENERAL_TEST_INPUTS="$(uberdev_child_inputs_build orchestrator.research.test_coverage \
  issue_path "$(uberdev_design_json_string "$issue_body_path")" \
  working_dir "$(uberdev_design_json_string "$WORKING_DIR_ABS")" \
  summary_path "$(uberdev_design_json_string "$research_test_summary_path")")"
uberdev_design_dispatch orchestrator.research.test_coverage orchestrator-research-test-coverage-a1 research-test-coverage research none '[]' "$GENERAL_TEST_INPUTS"
