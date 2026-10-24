"""Fix the row-swapped key decoding in the vendor SDK's StreamDockM18.

The SDK uses one table for both directions: logical key -> image slot, and
event code -> logical key. On firmware V3.M18V3_E the two numberings differ:
image slot 11 is the top-left key, but a press on the top-left key reports
code 1. So the SDK reports top-row presses as 11-15 and bottom-row presses
as 1-5. Event codes 1-15 already run top-left to bottom-right, so we use them
as the logical key directly. The three round keys (0x25/0x30/0x31) were
decoded correctly and keep the SDK mapping.

Importing this module swaps the patched class into the SDK's product table.
"""

from StreamDock import ProductIDs
from StreamDock.Devices.StreamDockM18 import StreamDockM18
from StreamDock.InputTypes import ButtonKey, EventType, InputEvent


class StreamDockM18Fixed(StreamDockM18):
    def decode_input_event(self, hardware_code: int, state: int) -> InputEvent:
        if 1 <= hardware_code <= 15:
            return InputEvent(
                event_type=EventType.BUTTON,
                key=ButtonKey(hardware_code),
                state=1 if state == 0x01 else 0,
            )
        return super().decode_input_event(hardware_code, state)


ProductIDs.g_products[:] = [
    (vid, pid, StreamDockM18Fixed if cls is StreamDockM18 else cls)
    for vid, pid, cls in ProductIDs.g_products
]
