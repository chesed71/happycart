"""빈 --ids 거부 + 정상 목록 전달 테스트 (DB 불필요)."""
import os
import subprocess
import sys
import unittest
from unittest import mock

HERE = os.path.dirname(os.path.abspath(__file__))
SCRIPTS = ["tokenize_ingredients.py", "judge.py", "promote.py"]
DEAD_DSN = "postgresql://u:p@127.0.0.1:1/none"
UUID1 = "00000000-0000-0000-0000-00000000000a"
UUID2 = "00000000-0000-0000-0000-00000000000b"


def run_script(script, *args):
    env = dict(os.environ, HAPPYCART_DSN=DEAD_DSN)
    return subprocess.run([sys.executable, script, *args], cwd=HERE, env=env,
                          capture_output=True, text=True, timeout=60)


class EmptyIdsRejected(unittest.TestCase):
    def test_empty_ids_exit_2(self):
        for script in SCRIPTS:
            for value in ("", ","):
                with self.subTest(script=script, value=value):
                    r = run_script(script, "--ids", value)
                    self.assertEqual(r.returncode, 2, r.stderr)
                    self.assertIn("--ids", r.stderr)

    def test_bad_uuid_exit_2(self):
        for script in SCRIPTS:
            with self.subTest(script=script):
                r = run_script(script, "--ids", "abc")
                self.assertEqual(r.returncode, 2, r.stderr)
                self.assertIn("uuid 형식이 아님", r.stderr)

    def test_valid_ids_help_ok(self):
        for script in SCRIPTS:
            with self.subTest(script=script):
                r = run_script(script, "--ids", "00000000-0000-0000-0000-000000000001", "--help")
                self.assertEqual(r.returncode, 0, r.stderr)


class IdsPassedAsList(unittest.TestCase):
    ARGV_IDS = f" {UUID1.upper()} ,{UUID2},"
    EXPECT = [UUID1, UUID2]

    def test_tokenize(self):
        import tokenize_ingredients as m
        with mock.patch.object(sys, "argv", ["x", "--ids", self.ARGV_IDS]), \
                mock.patch.object(m, "run_tokenize") as rt:
            m.main()
        self.assertEqual(rt.call_args[0][3], self.EXPECT)

    def test_judge(self):
        import judge as m
        with mock.patch.object(sys, "argv", ["x", "--ids", self.ARGV_IDS]), \
                mock.patch.object(m, "judge_collected") as jc, \
                mock.patch.object(m, "connect") as conn, \
                mock.patch.object(m, "current_rule_version", return_value="v"), \
                mock.patch.object(m, "resolve_app_dir", return_value="/x"):
            try:
                m.main()
            except Exception:
                pass  # 이후 커밋·집계 단계의 mock 한계는 무관
        self.assertEqual(jc.call_args[0][-1], self.EXPECT)

    def test_promote(self):
        import promote as m
        with mock.patch.object(sys, "argv", ["x", "--ids", self.ARGV_IDS]), \
                mock.patch.object(m, "run_promotion", return_value=(0, 0)) as rp, \
                mock.patch.object(m, "connect"):
            try:
                m.main()
            except Exception:
                pass
        self.assertEqual(rp.call_args.kwargs["ids"], self.EXPECT)


if __name__ == "__main__":
    unittest.main()
