"""Writes Assets/blank-cursor.dll: a resource-only DLL holding one cursor (id 1) that draws nothing.

WinUI shows a pointer shape only from a system shape or a cursor resource in a module, and has no "none". A Mac's
screen window draws the Mac's own pointer where this PC's is, so this PC's must not show there: the window sets this
cursor on the picture. The DLL has no code, no imports and no entry point; it is written here byte for byte so the
build needs no resource compiler. Run: python make-blank-cursor.py (then commit Assets/blank-cursor.dll, which it writes).
"""
import os
import struct

SIDE = 32
RT_CURSOR, RT_GROUP_CURSOR = 1, 12
CURSOR_ID, GROUP_ID, LANG = 1, 1, 0x0409

# The cursor: its hot spot, then a 1-bit bitmap twice its height (the picture, then the mask). A mask of all ones
# with a picture of all zeros leaves every pixel of the screen as it was.
mask_row = (SIDE + 31) // 32 * 4
header = struct.pack('<IiiHHIIiiII', 40, SIDE, SIDE * 2, 1, 1, 0, mask_row * SIDE * 2, 0, 0, 2, 0)
palette = struct.pack('<II', 0x00000000, 0x00FFFFFF)
cursor = struct.pack('<HH', 0, 0) + header + palette + b'\x00' * (mask_row * SIDE) + b'\xFF' * (mask_row * SIDE)
# The group that names it: one cursor, its size as the resource format has it (height doubled), 1 plane, 1 bit.
group = struct.pack('<HHH', 0, 2, 1) + struct.pack('<HHHHIH', SIDE, SIDE * 2, 1, 1, len(cursor), CURSOR_ID)

# .rsrc: a directory of types, each with one id, each with one language, each pointing at its bytes.
SECTION_RVA = 0x1000


def directory(entries):
    return struct.pack('<IIHHHH', 0, 0, 0, 0, 0, len(entries)) + b''.join(struct.pack('<II', i, o) for i, o in entries)


DIR, ENTRY = 16, 8
root_size = DIR + 2 * ENTRY
level = DIR + ENTRY
offsets = {
    'type_cursor': root_size, 'type_group': root_size + level,
    'lang_cursor': root_size + 2 * level, 'lang_group': root_size + 3 * level,
    'data_cursor': root_size + 4 * level, 'data_group': root_size + 4 * level + 16,
}
bytes_at = root_size + 4 * level + 32
cursor_at = bytes_at
group_at = cursor_at + (len(cursor) + 3) // 4 * 4
SUB = 0x80000000
rsrc = b''.join([
    directory([(RT_CURSOR, SUB | offsets['type_cursor']), (RT_GROUP_CURSOR, SUB | offsets['type_group'])]),
    directory([(CURSOR_ID, SUB | offsets['lang_cursor'])]),
    directory([(GROUP_ID, SUB | offsets['lang_group'])]),
    directory([(LANG, offsets['data_cursor'])]),
    directory([(LANG, offsets['data_group'])]),
    struct.pack('<IIII', SECTION_RVA + cursor_at, len(cursor), 0, 0),
    struct.pack('<IIII', SECTION_RVA + group_at, len(group), 0, 0),
])
assert len(rsrc) == bytes_at
rsrc += cursor + b'\x00' * (group_at - cursor_at - len(cursor)) + group
virtual_size = len(rsrc)
FILE_ALIGN, SECTION_ALIGN = 0x200, 0x1000
raw = rsrc + b'\x00' * (-len(rsrc) % FILE_ALIGN)

# The file: a DOS stub that only points at the PE header, the headers of a 64-bit DLL, one read-only data section.
dos = b'MZ' + b'\x00' * 58 + struct.pack('<I', 0x40)
coff = struct.pack('<HHIIIHH', 0x8664, 1, 0, 0, 0, 0xF0, 0x2000 | 0x0002 | 0x0020)  # DLL, executable image, large addresses
directories = [(0, 0)] * 16
directories[2] = (SECTION_RVA, virtual_size)  # the resource table
optional = struct.pack('<HBBIIIII', 0x20B, 14, 0, 0, len(raw), 0, 0, 0)  # PE32+, no code, no entry point
optional += struct.pack('<QIIHHHHHHIIIIHH', 0x180000000, SECTION_ALIGN, FILE_ALIGN, 6, 0, 0, 0, 6, 0, 0,
                        SECTION_RVA + (virtual_size + SECTION_ALIGN - 1) // SECTION_ALIGN * SECTION_ALIGN, FILE_ALIGN, 0,
                        2, 0x0100 | 0x0400)  # Windows GUI; data can't be run, no exception handlers
optional += struct.pack('<QQQQII', 0x100000, 0x1000, 0x100000, 0x1000, 0, 16)
optional += b''.join(struct.pack('<II', rva, size) for rva, size in directories)
assert len(optional) == 0xF0
section = b'.rsrc\x00\x00\x00' + struct.pack('<IIIIIIHHI', virtual_size, SECTION_RVA, len(raw), FILE_ALIGN, 0, 0, 0, 0, 0x40000040)
headers = dos + b'PE\x00\x00' + coff + optional + section
assert len(headers) <= FILE_ALIGN
image = headers + b'\x00' * (FILE_ALIGN - len(headers)) + raw

path = os.path.join(os.path.dirname(os.path.abspath(__file__)), 'Assets', 'blank-cursor.dll')
with open(path, 'wb') as f:
    f.write(image)
print(f'{path}: {len(image)} bytes')
