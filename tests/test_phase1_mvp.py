import os
import tempfile
import unittest
from datetime import datetime, timedelta

from zxtouch.guard import GuardEvaluator
from zxtouch.jobmanager import JobManager
from zxtouch.logging_store import FileLogger, LoggingStore
from zxtouch.plan import Plan, PlanBudget, RetryPolicy, Step, StepBudget
from zxtouch.resource_lock import ResourceLockManager
from zxtouch.runner import PlanRunner
from zxtouch.telemetry import TelemetryStore
from zxtouch.watchdog import BudgetLimits, BudgetUsage, Watchdog


class Phase1MvpTests(unittest.TestCase):
    def test_resource_lock_release_all_on_stop(self):
        lock = ResourceLockManager()
        self.assertTrue(lock.acquire("job1", "touch", "exclusive", 1000))
        self.assertTrue(lock.acquire("job1", "screen", "exclusive", 1000))
        self.assertEqual(lock.release_all("job1"), 2)
        self.assertFalse(lock.check_owner("job1", "touch"))

    def test_resource_lock_shared_read(self):
        lock = ResourceLockManager()
        self.assertTrue(lock.acquire("job1", "screen", "read", 1000))
        self.assertTrue(lock.acquire("job2", "screen", "read", 1000))
        self.assertFalse(lock.acquire("job3", "screen", "exclusive", 1000))
        self.assertTrue(lock.release("job1", "screen"))
        self.assertTrue(lock.check_owner("job2", "screen"))

    def test_checkpoint_restart_no_duplicate_step(self):
        with tempfile.TemporaryDirectory() as tmpdir:
            state_path = os.path.join(tmpdir, "state.json")
            jm = JobManager(state_path)
            plan = Plan(
                plan_id="p1",
                budgets=PlanBudget(),
                steps=[
                    Step(step_id="s1", type="record", payload={"value": "s1"}),
                    Step(step_id="s2", type="record", payload={"value": "s2"}),
                ],
            )
            job_id = jm.start("p1", plan, "owner")
            jm.update_checkpoint(job_id, 1)
            recorder = []
            runner = PlanRunner(jm, TelemetryStore(), LoggingStore(), Watchdog(BudgetLimits()), recorder=recorder)
            runner.run(job_id)
            self.assertEqual(recorder, ["s2"])

    def test_guard_timeout_and_retry(self):
        evaluator = GuardEvaluator()
        context = {"started_at": datetime.utcnow() - timedelta(milliseconds=200)}
        guard = {"type": "timeout_ms", "params": {"timeout_ms": 100}}
        result = evaluator.evaluate_step((guard,), context)
        self.assertFalse(result.ok)

    def test_watchdog_progress_timeout(self):
        with tempfile.TemporaryDirectory() as tmpdir:
            state_path = os.path.join(tmpdir, "state.json")
            jm = JobManager(state_path)
            plan = Plan(
                plan_id="p2",
                budgets=PlanBudget(),
                steps=[Step(step_id="s1", type="sleep", payload={"ms": 10})],
            )
            job_id = jm.start("p2", plan, "owner")
            runner = PlanRunner(jm, TelemetryStore(), LoggingStore(), Watchdog(BudgetLimits()))
            runner.state.last_progress_ts = (datetime.utcnow() - timedelta(milliseconds=200)).timestamp()
            runner.run(job_id, progress_timeout_ms=50)
            status = jm.status(job_id)
            self.assertEqual(status["state"], "HUNG")

    def test_logging_file_contains_step_events(self):
        with tempfile.TemporaryDirectory() as tmpdir:
            state_path = os.path.join(tmpdir, "state.json")
            jm = JobManager(state_path)
            plan = Plan(
                plan_id="p3",
                budgets=PlanBudget(),
                steps=[Step(step_id="s1", type="touch", payload={})],
            )
            job_id = jm.start("p3", plan, "owner")
            file_logger = FileLogger(tmpdir, max_bytes=1024)
            runner = PlanRunner(jm, TelemetryStore(), LoggingStore(), Watchdog(BudgetLimits()))
            runner.run(job_id, file_logger)
            log_path = file_logger.get_path(job_id)
            self.assertTrue(log_path.exists())
            content = log_path.read_text(encoding="utf-8")
            self.assertIn("start_step", content)
            self.assertIn("end_step", content)
            self.assertIn("job_finished", content)


if __name__ == "__main__":
    unittest.main()
