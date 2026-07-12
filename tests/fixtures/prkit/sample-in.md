subagent_type: uberdev:code-fixer
Skill(uberdev:post-impl-review)
next: /uberdev:solve https://example/issues/7
so a concurrent `/uberdev:goal` Phase 2b knows this PR's `/review-pr` is in-flight (avoids re-dispatching ours while the leaf solver's own is still running)
The locked marker is read by `/uberdev:goal` Phase 2b via `_uberdev_goal_locked_marker_for_pr_fresh` (lib/goal-state.sh). 
export UBERDEV_MODEL="opus"
_uberdev_config_read_load() { :; }
config at .claude/uberdev.local.md
path ${CLAUDE_PLUGIN_ROOT}/policy/model-routing-v1.json fallback ${PWD}/plugins/uberdev/policy/x.json
label uberdev-approved and marker review-pr:pending
clone https://github.com/TheFJK/UberDev then add TheFJK/uberdev to marketplace
Related skills: uberdev:brainstorm, /uberdev:write-plan, and the UberDev toolkit primer
inline: run `next: /uberdev:solve <URL>` then check the finding
