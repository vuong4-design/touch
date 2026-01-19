import os
import tempfile
import unittest
from datetime import datetime, timedelta

from zxtouch.jobmanager import JobManager
from zxtouch.lease import LeaseManager
from zxtouch.plan import Plan, PlanBudget, Step


class Phase2LeaseTests(unittest.TestCase):
    def test_lease_expires_autonomous(self):
        manager = LeaseManager()
        lease = manager.attach("lease1", "job1", "owner", ttl_ms=1, heartbeat_interval_ms=100)
        lease.lease_expiry_ts = datetime.utcnow() - timedelta(milliseconds=1)
        self.assertTrue(manager.check_expired("lease1"))
        self.assertEqual(lease.state, "EXPIRED")

    def test_heartbeat_refreshes_ttl(self):
        manager = LeaseManager()
        lease = manager.attach("lease2", "job2", "owner", ttl_ms=50, heartbeat_interval_ms=100)
        old_expiry = lease.lease_expiry_ts
        self.assertTrue(manager.heartbeat("lease2"))
        self.assertGreater(lease.lease_expiry_ts, old_expiry)

    def test_detach_keeps_job_running(self):
        with tempfile.TemporaryDirectory() as tmpdir:
            state_path = os.path.join(tmpdir, "state.json")
            jm = JobManager(state_path)
            plan = Plan(plan_id="p1", budgets=PlanBudget(), steps=[Step(step_id="s1", type="touch", payload={})])
            job_id = jm.start("p1", plan, "owner")
            manager = LeaseManager()
            lease = manager.attach("lease3", job_id, "owner", ttl_ms=1000, heartbeat_interval_ms=100)
            self.assertTrue(manager.detach(lease.lease_id))
            self.assertEqual(jm.status(job_id)["state"], "RUNNING")

    def test_reattach_syncs_state(self):
        manager = LeaseManager()
        lease = manager.attach("lease4", "job4", "owner", ttl_ms=1000, heartbeat_interval_ms=100)
        manager.detach(lease.lease_id)
        lease2 = manager.reattach("lease4", "job4", "owner", ttl_ms=1000, heartbeat_interval_ms=100)
        self.assertEqual(lease2.job_id, "job4")
        self.assertEqual(lease2.state, "ATTACHED")


if __name__ == "__main__":
    unittest.main()
