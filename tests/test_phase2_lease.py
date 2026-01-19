import os
import tempfile
import unittest
from datetime import datetime, timedelta

from zxtouch.jobmanager import JobManager
from zxtouch.lease import LeaseManager
from zxtouch.plan import Plan, PlanBudget, Step


class Phase2LeaseTests(unittest.TestCase):
    def setUp(self):
        self.now = datetime(2025, 1, 1, 0, 0, 0)
        self.manager = LeaseManager(now_fn=lambda: self.now)

    def test_lease_expires_autonomous(self):
        lease = self.manager.attach("lease1", "job1", "owner", ttl_ms=1, heartbeat_interval_ms=100)
        self.now = self.now + timedelta(milliseconds=2)
        self.assertTrue(self.manager.check_expired("lease1"))
        self.assertEqual(lease.state, "EXPIRED")

    def test_heartbeat_refreshes_ttl(self):
        lease = self.manager.attach("lease2", "job2", "owner", ttl_ms=50, heartbeat_interval_ms=100)
        old_expiry = lease.lease_expiry_ts
        self.now = self.now + timedelta(milliseconds=10)
        self.assertTrue(self.manager.heartbeat("lease2"))
        self.assertGreater(lease.lease_expiry_ts, old_expiry)

    def test_detach_keeps_job_running(self):
        with tempfile.TemporaryDirectory() as tmpdir:
            state_path = os.path.join(tmpdir, "state.json")
            jm = JobManager(state_path)
            plan = Plan(plan_id="p1", budgets=PlanBudget(), steps=[Step(step_id="s1", type="touch", payload={})])
            job_id = jm.start("p1", plan, "owner")
            lease = self.manager.attach("lease3", job_id, "owner", ttl_ms=1000, heartbeat_interval_ms=100)
            self.assertTrue(self.manager.detach(lease.lease_id))
            self.assertEqual(jm.status(job_id)["state"], "RUNNING")

    def test_reattach_syncs_state(self):
        lease = self.manager.attach("lease4", "job4", "owner", ttl_ms=1000, heartbeat_interval_ms=100)
        self.manager.detach(lease.lease_id)
        lease2 = self.manager.reattach("lease4", "job4", "owner", ttl_ms=1000, heartbeat_interval_ms=100)
        self.assertEqual(lease2.job_id, "job4")
        self.assertEqual(lease2.state, "ATTACHED")

    def test_duplicate_attach_rejected(self):
        self.manager.attach("lease5", "job5", "owner", ttl_ms=1000, heartbeat_interval_ms=100)
        self.now = self.now + timedelta(milliseconds=1)
        with self.assertRaises(ValueError):
            self.manager.attach("lease6", "job5", "owner2", ttl_ms=1000, heartbeat_interval_ms=100)

    def test_late_heartbeat_no_revive(self):
        lease = self.manager.attach("lease7", "job7", "owner", ttl_ms=10, heartbeat_interval_ms=100)
        self.now = self.now + timedelta(milliseconds=20)
        self.assertFalse(self.manager.heartbeat("lease7"))
        self.assertEqual(lease.state, "EXPIRED")

    def test_detach_idempotent(self):
        lease = self.manager.attach("lease8", "job8", "owner", ttl_ms=1000, heartbeat_interval_ms=100)
        self.assertTrue(self.manager.detach(lease.lease_id))
        self.assertFalse(self.manager.detach(lease.lease_id))

    def test_invalidate_on_job_stop(self):
        with tempfile.TemporaryDirectory() as tmpdir:
            state_path = os.path.join(tmpdir, "state.json")
            jm = JobManager(state_path)
            plan = Plan(plan_id="p2", budgets=PlanBudget(), steps=[Step(step_id="s1", type="touch", payload={})])
            job_id = jm.start("p2", plan, "owner")
            lease = self.manager.attach("lease9", job_id, "owner", ttl_ms=1000, heartbeat_interval_ms=100)
            jm.stop(job_id, "FAILED", lease_manager=self.manager)
            self.assertEqual(lease.state, "EXPIRED")


if __name__ == "__main__":
    unittest.main()
