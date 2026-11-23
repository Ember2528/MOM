-- Deliberately unloadable harness-only extension. Production discovery must
-- quarantine this ID without rejecting candidates that do not reference it.
error('synthetic unused extension load failure')
