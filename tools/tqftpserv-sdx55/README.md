# tqftpserv-sdx55

Patched `linux-msm/tqftpserv` (BSD-3-Clause) adapted for external PCIe/MHI `SDX55M` modems on Qualcomm SM8250 boards:

- Publishes QRTR Service `4096` versions `1..10` on 10 separate QRTR sockets (matching stock vendor `tftp_server`, because `qrtr_publish()` overwrites prior registrations on the same fd).
- Uses 2 MiB socket buffers with `EAGAIN`/`ENOBUFS` retry for large MCFG transfers.
- Maps `/readonly/firmware/image/...` directly to `/lib/firmware/...` and `/readwrite` / `/shared` / `/hlos` to `/var/lib/tqftpserv/...` without scanning `/sys/class/remoteproc` (which does not exist for PCIe-attached SDX55M).

Build on ARM64 target (`libqrtr-dev` installed):

```bash
make -C tools/tqftpserv-sdx55
```
