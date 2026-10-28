# Handover: `main` was rewritten - move your work onto it

From: Claude Code session (2026-10-28) · To: Codex (or any agent with a
worktree of this repository) · Owner: Vilson

## What happened

All commits on GitHub were credited to the wrong GitHub account
(`vilsongaertner`, through the machine's global work email) and 33 of them
carried a `Co-Authored-By: Claude` trailer. The owner wants the history to
show only his GitHub user **vgartner**. So `main` was rewritten and
force-pushed:

- every commit's author and committer is now
  `Vilson Cristiano Gärtner <vgartner@gmail.com>`;
- no `Co-Authored-By:` trailers or AI signatures remain;
- **file contents are identical** (same tree), dates unchanged; only the
  commit hashes changed. Old `main` tip `045bce3` = new `c2cc2d4`; old
  `de35ff9` ("Master and verify final video audio...") = new `65eb108`.

The repository's local git config now sets `user.email vgartner@gmail.com`
(it applies to every worktree of this repository). New rule in
[AGENTS.md](../../AGENTS.md) ("Rules"): commits and pull requests carry only
the contributor's GitHub identity - **no AI co-author trailers or
signatures**, even if your defaults add them.

## What you need to do

Your worktree `video-followups` has 4 commits not on GitHub (50495e9,
9aacfec, 6fa0e5a, c3b2a57), based on the old `de35ff9` and made with the
work email. Move them onto the new `main` with the right identity:

```bash
git fetch origin
git config user.email          # must print vgartner@gmail.com
git rebase --onto origin/main de35ff9 video-followups
git rebase origin/main --exec 'git commit --amend --no-edit --reset-author'
git log --format='%h %ae %s' origin/main..HEAD   # 4 commits, all vgartner@gmail.com, no trailers
```

Then run the checks that cover them (`python3 tools/devagent/test_stage.py`,
`python3 tools/video/test_encoders.py`, the native video-take test from
[docs/DEVAGENT.md](../DEVAGENT.md)), and push to `main` as a fast-forward
(`git push origin HEAD:main`). Never force-push `main`.

- The old branch `gameplay-video` (worktree `city-invaders-gameplay-video`)
  is fully merged in the new `main`: nothing to bring over; it can be
  removed when you no longer need it.
- Don't push any branch or commit created before this rewrite as it is:
  it would bring the old hashes, the work email and the trailers back.
- Godot's generated `godot/scripts/video_actions.gd.uid` and
  `video_stage.gd.uid` are untracked in two worktrees; commit them once,
  from one worktree (the repository versions the other scripts' `.uid`).

## Then

Carry on with [the video follow-ups](2026-10-28-video-followups.md)
(items 5-6 - the v4 recording, which your last commit reports) and report
back what was pushed and tested.
