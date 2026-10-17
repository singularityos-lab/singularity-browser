namespace Singularity.Apps.Browser {

    public errordomain ZipError {
        INVALID,
        UNSUPPORTED,
        TOO_LARGE
    }

    public class ZipArchive : Object {
        private const uint32 END_SIGNATURE = 0x06054b50;
        private const uint32 ENTRY_SIGNATURE = 0x02014b50;
        private const uint32 LOCAL_SIGNATURE = 0x04034b50;
        private const uint MAX_ENTRIES = 20000;
        private const uint64 MAX_TOTAL = 512 * 1024 * 1024;

        public static string[] extract (Bytes archive, File destination) throws Error {
            unowned uint8[] data = archive.get_data ();
            size_t end = find_end (data);
            uint entries = read_u16 (data, end + 10);
            uint32 directory_size = read_u32 (data, end + 12);
            uint32 directory_offset = read_u32 (data, end + 16);
            if (entries == 0xffff || directory_offset == 0xffffffff) throw new ZipError.UNSUPPORTED ("Large archives are not supported");
            if (entries > MAX_ENTRIES) throw new ZipError.TOO_LARGE ("The archive has too many files");
            if ((size_t) directory_offset + directory_size > end) throw new ZipError.INVALID ("The archive directory is damaged");

            string root = destination.get_path ();
            string[] written = {};
            uint64 total = 0;
            size_t position = directory_offset;
            for (uint i = 0; i < entries; i++) {
                if (position + 46 > end || read_u32 (data, position) != ENTRY_SIGNATURE) {
                    throw new ZipError.INVALID ("The archive directory is damaged");
                }
                uint flags = read_u16 (data, position + 8);
                uint method = read_u16 (data, position + 10);
                uint32 compressed = read_u32 (data, position + 20);
                uint32 size = read_u32 (data, position + 24);
                uint name_length = read_u16 (data, position + 28);
                uint extra_length = read_u16 (data, position + 30);
                uint comment_length = read_u16 (data, position + 32);
                uint32 local = read_u32 (data, position + 42);
                if (position + 46 + name_length > end) throw new ZipError.INVALID ("The archive directory is damaged");
                unowned string raw = (string) ((uint8*) data + position + 46);
                string name = raw.ndup (name_length);
                if (name.length != name_length) throw new ZipError.INVALID ("The archive contains an unsafe path");
                position += 46 + name_length + extra_length + comment_length;

                if ((flags & 1) != 0) throw new ZipError.UNSUPPORTED ("Encrypted archives are not supported");
                string? relative = safe_path (name);
                if (relative == null) throw new ZipError.INVALID ("The archive contains an unsafe path: %s".printf (name));
                if (name.has_suffix ("/")) {
                    DirUtils.create_with_parents (Path.build_filename (root, relative), 0755);
                    continue;
                }
                total += size;
                if (total > MAX_TOTAL) throw new ZipError.TOO_LARGE ("The archive is too large");

                if ((size_t) local + 30 > end || read_u32 (data, local) != LOCAL_SIGNATURE) {
                    throw new ZipError.INVALID ("The archive entry %s is damaged".printf (name));
                }
                size_t start = local + 30 + read_u16 (data, local + 26) + read_u16 (data, local + 28);
                if (start + compressed > end) throw new ZipError.INVALID ("The archive entry %s is truncated".printf (name));
                var payload = archive.slice (start, start + compressed);
                Bytes content;
                if (method == 0) {
                    content = payload;
                } else if (method == 8) {
                    content = inflate (payload, size);
                } else {
                    throw new ZipError.UNSUPPORTED ("The archive uses an unsupported compression");
                }
                if (content.get_size () != size) throw new ZipError.INVALID ("The archive entry %s has the wrong size".printf (name));

                string path = Path.build_filename (root, relative);
                DirUtils.create_with_parents (Path.get_dirname (path), 0755);
                FileUtils.set_data (path, content.get_data ());
                written += relative;
            }
            return written;
        }

        public static string? safe_path (string name) {
            string clean = name.replace ("\\", "/");
            if (clean.has_prefix ("/") || clean == "") return null;
            string[] parts = {};
            foreach (string part in clean.split ("/")) {
                if (part == "" || part == ".") continue;
                if (part == "..") return null;
                parts += part;
            }
            if (parts.length == 0) return null;
            return string.joinv ("/", parts);
        }

        private static Bytes inflate (Bytes payload, uint32 size) throws Error {
            var decompressor = new ZlibDecompressor (ZlibCompressorFormat.RAW);
            var input = new MemoryInputStream.from_bytes (payload);
            var stream = new ConverterInputStream (input, decompressor);
            var output = new MemoryOutputStream.resizable ();
            uint8[] buffer = new uint8[65536];
            uint64 read = 0;
            ssize_t count;
            while ((count = stream.read (buffer)) > 0) {
                read += count;
                if (read > size) throw new ZipError.INVALID ("An archive entry is larger than declared");
                output.write (buffer[0:count]);
            }
            output.close ();
            return output.steal_as_bytes ();
        }

        private static size_t find_end (uint8[] data) throws ZipError {
            if (data.length < 22) throw new ZipError.INVALID ("The archive is empty");
            size_t lowest = data.length > 65557 ? data.length - 65557 : 0;
            for (size_t i = data.length - 22; ; i--) {
                if (read_u32 (data, i) == END_SIGNATURE) return i;
                if (i == lowest) break;
            }
            throw new ZipError.INVALID ("The archive has no directory");
        }

        private static uint read_u16 (uint8[] data, size_t offset) {
            return data[offset] | (data[offset + 1] << 8);
        }

        private static uint32 read_u32 (uint8[] data, size_t offset) {
            return data[offset] | (data[offset + 1] << 8) | (data[offset + 2] << 16) | ((uint32) data[offset + 3] << 24);
        }
    }
}
