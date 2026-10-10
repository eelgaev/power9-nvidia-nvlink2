# Booting the test kernel on an AC922

POWER9 OpenPOWER systems such as the AC922 do not run GRUB. The firmware's
boot loader, **petitboot**, reads `/boot/grub2/grub.cfg`, the BLS entries in
`/boot/loader/entries/` and `/boot/grub2/grubenv` itself, then kexecs the
chosen kernel. Consequences:

- GRUB one-shot boots (`grub2-reboot`, `next_entry`) have no effect.
- The kernel is chosen on the petitboot menu, on the host console.
- How petitboot picks its default entry depends on the firmware's
  petitboot version. Check what it marks as default (step 3) instead of
  assuming it follows `grubby --default-kernel`.

## 1. Before rebooting

```sh
grubby --default-kernel                # the kernel you expect to come back to
grubby --info=ALL | grep -E '^(index|kernel|title)'
grep UPDATEDEFAULT /etc/sysconfig/kernel   # =no while the test kernel is installed
```

If the default is not the kernel you want to return to, fix it first
(`grubby --set-default /boot/vmlinuz-<release>`).

## 2. Open the host console (from the BMC)

OpenBMC exposes the host console over SSH on port 2200:

```sh
ssh -p 2200 root@<bmc>           # exit with "~."
```

(Alternatives: `ipmitool -I lanplus -H <bmc> -U <user> -P <pass> sol activate`,
or the console in the BMC web interface.)

Keep this session open across the reboot.

## 3. Pick the kernel in petitboot

Reboot the host from its own shell (`systemctl reboot`) or from the BMC.
When petitboot's menu appears it shows a countdown ("Booting in N sec");
**press any arrow key** to stop it. Then:

1. Note which entry is highlighted / marked as default: that is what an
   unattended reboot will boot.
2. Select `Red Hat Enterprise Linux (5.14.0-741.9.1.npu2.el9_9.ppc64le)` and
   press Enter. (`e` edits the entry's command line for this boot only.)

To get more time to react, raise the autoboot timeout from petitboot's
*System configuration* screen, or from the running host:
`nvram --update-config petitboot,timeout=30`.

## 4. Return to the stock kernel

Reboot and let petitboot autoboot, or pick the stock entry. If the test
kernel hangs, power-cycle from the BMC (`obmcutil poweroff && obmcutil
poweron` on the BMC shell, or `ipmitool ... chassis power cycle`) and watch
the console: petitboot autoboots the default entry, which is unchanged.

## 5. Remove the test kernel

```sh
rpm -e kernel-5.14.0_741.9.1.npu2.el9_9.ppc64le kernel-devel-5.14.0_741.9.1.npu2.el9_9.ppc64le
```
