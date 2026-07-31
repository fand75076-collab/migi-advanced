# Locked-session runtime probe

- Probe time: 2026-07-31 20:32 CST
- Installed process: PID `1765`, `MigiAdvanced`
- Window: ID `8624`, on-screen, layer `3`, sharing state `1`
- Window bounds: `104 x 122` points at `(1200, 321)`
- Session state: `CGSSessionScreenIsLocked = 1`
- Window capture attempts: `120`
- Successful window frames: `0`
- Capture error: `could not create image from window`
- Full-desktop fallback contained only four non-black pixels.

This result confirms that the black capture was caused by macOS lock-screen
privacy, not by an empty Migi Metal drawable. The application was not restarted
or modified. Post-fix visual evidence was obtained separately through Migi's
in-process Metal capture path.
