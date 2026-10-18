ExUnit.start()

# Test hygiene: the skill layer reads *the developer's machine* by default
# (`~/.agents/skills`, `~/work/skills/.agents/skills`), so an unpinned run would (a) depend on
# whatever skills happen to be installed and (b) inject them into every conductor system prompt
# built in a test (issue #23).
#
# `ATHANOR_SKILL_PATHS` is therefore pinned, process-globally, to a path that cannot exist: the
# default roots are never reached, so `Athanor.Skills.discover/1` finds nothing unless a test
# passes an explicit `paths:` at its own tmp fixture tree. That one pin is the whole guarantee —
# it also covers `Athanor.Agent`, whose per-session `skill_opts` fall back to `Config.skill_paths/0`.
#
# `ATHANOR_SKILLS` is deliberately *not* pinned: leaving the master switch at its default keeps
# `enabled:` orthogonal, so a discovery test only has to supply roots, and the switch's own
# behaviour is asserted explicitly in `test/athanor/skills_config_test.exs`.
System.put_env("ATHANOR_SKILL_PATHS", "/nonexistent/athanor-test-skill-root")
