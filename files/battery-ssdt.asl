/*
 * Fake battery for the VM (hypr-gpu-passthrough).
 *
 * NVIDIA's Windows driver refuses to start a laptop ("mobile") GPU with Code 43 when the machine
 * reports no battery. This ACPI table adds a minimal, always-full battery to the guest.
 * Compiled at install time with: iasl -p <output> battery-ssdt.asl
 */
DefinitionBlock ("", "SSDT", 1, "HGP", "BATTERY", 0x00000001)
{
    External (_SB_.PCI0, DeviceObj)

    Scope (_SB.PCI0)
    {
        Device (BAT0)
        {
            Name (_HID, EisaId ("PNP0C0A"))  // Control Method Battery
            Name (_UID, Zero)

            Method (_STA, 0, NotSerialized)
            {
                Return (0x1F)  // present, enabled, shown, working, battery present
            }

            Method (_BIF, 0, NotSerialized)  // static battery information
            {
                Return (Package (0x0D)
                {
                    One,     // power unit: mA / mAh
                    0x1770,  // design capacity: 6000 mAh
                    0x1770,  // last full charge capacity
                    One,     // rechargeable
                    0x39D0,  // design voltage: 14800 mV
                    0x0258,  // warning level
                    0x012C,  // low level
                    0x3C,    // granularity 1
                    0x3C,    // granularity 2
                    "",      // model
                    "",      // serial number
                    "LION",  // type
                    ""       // OEM
                })
            }

            Method (_BST, 0, NotSerialized)  // current battery status
            {
                Return (Package (0x04)
                {
                    Zero,    // not charging or discharging
                    Zero,    // present rate
                    0x1770,  // remaining capacity: full
                    0x39D0   // present voltage
                })
            }
        }
    }
}
