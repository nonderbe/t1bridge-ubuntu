// SPDX-License-Identifier: GPL-2.0
/*
 * Tell the Apple T1 (ACPI APP7777, \_SB.PCI0.XHC1.RHUB.ASOC) when the host
 * sleeps and wakes, through its SOCW method, as macOS does. Without SOCW(1)
 * after a deep (S3) sleep the T1 stays dark: no Touch Bar, no Touch ID.
 *
 * This is the SOCW part of the legacy apple-ibridge driver, alone, for the
 * T1Bridge stack (which blocks apple-ibridge). It evaluates only SOCW, with
 * the fixed arguments 0 and 1; never FRST or any other method.
 */
#include <linux/acpi.h>
#include <linux/module.h>

static void apple_t1_socw(struct acpi_device *adev, u64 on)
{
	acpi_status status;

	status = acpi_execute_simple_method(adev->handle, "SOCW", on);
	if (ACPI_FAILURE(status))
		dev_warn(&adev->dev, "SOCW(%llu) failed: %s\n", on,
			 acpi_format_exception(status));
}

static int apple_t1_socw_add(struct acpi_device *adev)
{
	if (!acpi_has_method(adev->handle, "SOCW"))
		return -ENODEV;

	/* Make sure the T1 is on, as apple-ibridge did at probe. */
	apple_t1_socw(adev, 1);
	return 0;
}

static int apple_t1_socw_suspend(struct device *dev)
{
	apple_t1_socw(to_acpi_device(dev), 0);
	return 0;
}

static int apple_t1_socw_resume(struct device *dev)
{
	apple_t1_socw(to_acpi_device(dev), 1);
	return 0;
}

static const struct dev_pm_ops apple_t1_socw_pm = {
	.suspend = apple_t1_socw_suspend,
	.resume = apple_t1_socw_resume,
	.restore = apple_t1_socw_resume,
};

static const struct acpi_device_id apple_t1_socw_ids[] = {
	{ "APP7777", 0 },
	{ }
};
MODULE_DEVICE_TABLE(acpi, apple_t1_socw_ids);

static struct acpi_driver apple_t1_socw_driver = {
	.name = "apple-t1-socw",
	.ids = apple_t1_socw_ids,
	.ops = {
		.add = apple_t1_socw_add,
	},
	.drv = {
		.pm = &apple_t1_socw_pm,
	},
};
module_acpi_driver(apple_t1_socw_driver);

MODULE_DESCRIPTION("Apple T1 host sleep/wake notification (ASOC.SOCW)");
MODULE_LICENSE("GPL");
