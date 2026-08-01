"""Scheduled maintenance tasks.

Run out-of-process (cron, a systemd timer, or a one-shot container), not on a
background thread inside the API. With more than one API replica an in-process
scheduler would run the same purge several times concurrently, and a long purge
would compete with request handling for the connection pool.
"""
