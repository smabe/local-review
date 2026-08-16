#!/usr/bin/env python3
"""Regression tests for scripts/local_review.py's default review scope.

The break each test catches: get_diff([]) reverting to bare `git diff HEAD`,
which omits untracked files — an only-untracked change would report an empty
diff, and a mixed change would be reviewed without its new files.
"""

import importlib.util
import os
import subprocess
import tempfile
import unittest

_SPEC = importlib.util.spec_from_file_location(
    "local_review",
    os.path.join(os.path.dirname(__file__), "local_review.py"),
)
local_review = importlib.util.module_from_spec(_SPEC)
_SPEC.loader.exec_module(local_review)


class DefaultScopeIncludesUntracked(unittest.TestCase):
    def setUp(self):
        self._prev_cwd = os.getcwd()
        self._tmp = tempfile.TemporaryDirectory()
        os.chdir(self._tmp.name)
        subprocess.run(["git", "init", "-q"], check=True)
        subprocess.run(["git", "config", "user.email", "t@t"], check=True)
        subprocess.run(["git", "config", "user.name", "t"], check=True)
        with open("tracked.txt", "w") as f:
            f.write("original\n")
        subprocess.run(["git", "add", "tracked.txt"], check=True)
        subprocess.run(["git", "commit", "-qm", "init"], check=True)

    def tearDown(self):
        os.chdir(self._prev_cwd)
        self._tmp.cleanup()

    def test_only_untracked_change_is_not_an_empty_diff(self):
        with open("brand_new.py", "w") as f:
            f.write("print('hello')\n")

        diff = local_review.get_diff([])

        self.assertIn("brand_new.py", diff)

    def test_mixed_change_includes_both_tracked_and_untracked(self):
        with open("tracked.txt", "w") as f:
            f.write("modified\n")
        with open("brand_new.py", "w") as f:
            f.write("print('hello')\n")

        diff = local_review.get_diff([])

        self.assertIn("tracked.txt", diff)
        self.assertIn("brand_new.py", diff)

    def test_empty_repo_falls_back_to_untracked_only(self):
        # Fresh repo, no commits: `git diff HEAD` cannot resolve, but an
        # untracked file must still reach the review scope.
        import shutil
        shutil.rmtree(".git")
        subprocess.run(["git", "init", "-q"], check=True)
        with open("brand_new.py", "w") as f:
            f.write("print('hello')\n")

        diff = local_review.get_diff([])

        self.assertIn("brand_new.py", diff)

    def test_explicit_range_args_do_not_pull_in_untracked(self):
        with open("brand_new.py", "w") as f:
            f.write("print('hello')\n")

        diff = local_review.get_diff(["HEAD"])
        # Untracked-union applies only to the no-args default; an explicit
        # range means the caller asked for exactly that range.
        # (args=["HEAD"] and args=[] differ only in this union.)
        self.assertNotIn("brand_new.py", diff)


if __name__ == "__main__":
    unittest.main()
