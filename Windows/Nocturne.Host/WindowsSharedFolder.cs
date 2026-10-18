using System.ComponentModel;
using System.Runtime.InteropServices;
using System.Runtime.Versioning;
using System.Text;
using Microsoft.Win32.SafeHandles;

namespace Nocturne.Host;

public static class SharedPath
{
    public static string[] Components(string path)
    {
        if (Encoding.UTF8.GetByteCount(path) > 4096) throw new IOException("Invalid shared path.");
        if (path == "") return [];
        var parts = path.Split('/');
        foreach (var part in parts)
        {
            var stem = part.Split('.')[0].TrimEnd(' ');
            if (part.Length == 0 || part is "." or ".." || part.EndsWith('.') || part.EndsWith(' ') ||
                part.Any(c => c < 32 || "<>:\"\\|?*".Contains(c)) || part.StartsWith(".nocturne-upload-", StringComparison.OrdinalIgnoreCase) ||
                new[] { "CON", "PRN", "AUX", "NUL", "CONIN$", "CONOUT$" }.Contains(stem, StringComparer.OrdinalIgnoreCase) ||
                (stem.Length == 4 && (stem.StartsWith("COM", StringComparison.OrdinalIgnoreCase) || stem.StartsWith("LPT", StringComparison.OrdinalIgnoreCase)) &&
                    "123456789¹²³".Contains(stem[3]))) throw new IOException("This path is outside the shared folder or uses a reserved Windows name.");
        }
        return parts;
    }
}

/// Open every directory without following reparse points and deny mutation/rename while in use.
[SupportedOSPlatform("windows")]
public sealed class WindowsSharedFolder : IWorkspaceFiles
{
    private readonly string root;
    private readonly List<SafeFileHandle> rootLocks;
    public WindowsSharedFolder(string path)
    {
        root = Path.GetFullPath(path);
        if (root.StartsWith("\\", StringComparison.Ordinal)) throw new IOException("Choose a local folder instead of a network share.");
        Directory.CreateDirectory(root);
        rootLocks = [];
        try
        {
            var current = Path.GetPathRoot(root)!;
            rootLocks.Add(Open(current, true));
            foreach (var part in root[current.Length..].Split(Path.DirectorySeparatorChar, StringSplitOptions.RemoveEmptyEntries))
            {
                current = Path.Combine(current, part); rootLocks.Add(Open(current, true));
            }
        }
        catch { Dispose(); throw; }
    }

    private (string Path, List<SafeFileHandle> Locks) DirectoryPath(string[] components)
    {
        var handles = new List<SafeFileHandle>(); var current = root;
        try
        {
            foreach (var component in components)
            { current = Path.Combine(current, component); handles.Add(Open(current, true)); }
            return (current, handles);
        }
        catch { foreach (var handle in handles) handle.Dispose(); throw; }
    }
    public RemoteFile[] List(string path)
    {
        var location = DirectoryPath(SharedPath.Components(path));
        try
        {
            var result = new List<RemoteFile>();
            foreach (var item in Directory.EnumerateFileSystemEntries(location.Path))
            {
                var name = Path.GetFileName(item);
                if (name.StartsWith(".nocturne-upload-", StringComparison.OrdinalIgnoreCase)) continue;
                try
                {
                    SharedPath.Components(name);
                    using var file = Open(item, (File.GetAttributes(item) & FileAttributes.Directory) != 0);
                    if (!GetFileInformationByHandle(file, out var info)) throw new Win32Exception();
                    bool directory = (info.Attributes & 0x10) != 0;
                    long size = ((long)info.SizeHigh << 32) | info.SizeLow;
                    var ticks = ((long)info.WriteHigh << 32) | info.WriteLow;
                    double modified = (DateTime.FromFileTimeUtc(ticks) - new DateTime(2001, 1, 1, 0, 0, 0, DateTimeKind.Utc)).TotalSeconds;
                    result.Add(new(name, path.Length == 0 ? name : path + "/" + name, directory, directory ? 0 : size, modified));
                }
                catch (Exception ex) when (ex is IOException or UnauthorizedAccessException or Win32Exception) { continue; }
                if (result.Count > 2000) throw new IOException("This folder has too many items. Choose a smaller shared folder.");
            }
            return result.OrderByDescending(f => f.IsDirectory).ThenBy(f => f.Name, StringComparer.OrdinalIgnoreCase).ToArray();
        }
        finally { foreach (var handle in location.Locks) handle.Dispose(); }
    }
    public (byte[] Data, long Size, bool Eof) Read(string path, long offset)
    {
        var parts = SharedPath.Components(path);
        if (parts.Length == 0 || offset < 0) throw new IOException("Invalid file transfer.");
        var parent = DirectoryPath(parts[..^1]);
        try
        {
            using var handle = Open(Path.Combine(parent.Path, parts[^1]), false);
            using var stream = new FileStream(handle, FileAccess.Read);
            var length = stream.Length;
            if (offset > length) throw new IOException("Invalid file offset.");
            stream.Position = offset;
            var buffer = new byte[(int)Math.Min(Wire.ChunkSize, length - offset)];
            stream.ReadExactly(buffer);
            return (buffer, length, offset + buffer.Length >= length);
        }
        finally { foreach (var handle in parent.Locks) handle.Dispose(); }
    }
    public IUpload BeginUpload(string path, long size)
    {
        var parts = SharedPath.Components(path);
        if (parts.Length == 0 || size < 0 || size > 100L * 1024 * 1024 * 1024) throw new IOException("Invalid file transfer.");
        var parent = DirectoryPath(parts[..^1]);
        try
        {
            var destination = Path.Combine(parent.Path, parts[^1]);
            if (File.Exists(destination) || Directory.Exists(destination)) throw new IOException("A file with this name already exists. Rename it before sending.");
            return new Upload(destination, size, parent.Locks);
        }
        catch { foreach (var handle in parent.Locks) handle.Dispose(); throw; }
    }

    private sealed class Upload : IUpload
    {
        public string Id { get; } = Guid.NewGuid().ToString();
        public long Received { get; private set; }
        private readonly long expected;
        private readonly string temporary, destination;
        private readonly List<SafeFileHandle> locks;
        private FileStream? stream;
        private bool committed;
        public Upload(string destination, long expected, List<SafeFileHandle> locks)
        {
            this.destination = destination; this.expected = expected; this.locks = locks;
            temporary = Path.Combine(Path.GetDirectoryName(destination)!, ".nocturne-upload-" + Id);
            // DELETE access permits an atomic rename through this handle, without
            // reopening a protected parent directory for write access.
            var handle = CreateFileW(temporary, 0x40010000, 0, 0, 1, 0x00200000, 0);
            if (handle.IsInvalid)
            { handle.Dispose(); throw new IOException("Cannot create the upload file.", new Win32Exception()); }
            try { stream = new(handle, FileAccess.Write); }
            catch { handle.Dispose(); File.Delete(temporary); throw; }
        }
        public void Append(byte[] data, long offset)
        {
            if (stream == null || committed || offset != Received || data.Length > Wire.ChunkSize || data.Length > expected - Received)
                throw new IOException("The transfer is incomplete or out of order. Start it again.");
            stream.Write(data); Received += data.Length;
        }
        public void Commit()
        {
            if (stream == null || committed || Received != expected) throw new IOException("The transfer is incomplete. Start it again.");
            stream.Flush(true);
            // A simple native rename stays in the source directory. MoveFile
            // reopens the destination parent for write and conflicts with its
            // mutation guard, even when source and destination share a parent.
            RenameWithinDirectory(stream.SafeFileHandle, Path.GetFileName(destination));
            committed = true; stream.Dispose(); stream = null;
        }
        public void Dispose()
        {
            stream?.Dispose(); stream = null;
            try { if (!committed) File.Delete(temporary); }
            finally { foreach (var handle in locks) handle.Dispose(); locks.Clear(); }
        }
    }

    private static void RenameWithinDirectory(SafeFileHandle file, string name)
    {
        var encoded = Encoding.Unicode.GetBytes(name);
        var size = checked(Marshal.SizeOf<RenameInfo>() + encoded.Length);
        var buffer = Marshal.AllocHGlobal(size);
        try
        {
            // ReplaceIfExists/Flags and RootDirectory remain zero. With a simple
            // name, FileRenameInformation renames within the existing directory
            // and fails atomically if the destination already exists.
            Marshal.StructureToPtr(new RenameInfo { NameLength = (uint)encoded.Length }, buffer, false);
            Marshal.Copy(encoded, 0, buffer + (int)Marshal.OffsetOf<RenameInfo>(nameof(RenameInfo.Name)), encoded.Length);
            int status = NtSetInformationFile(file, out _, buffer, (uint)size, 10);
            if (status < 0) throw new IOException("Cannot publish the upload file.", new Win32Exception((int)RtlNtStatusToDosError(status)));
        }
        finally { Marshal.FreeHGlobal(buffer); }
    }

    private static SafeFileHandle Open(string path, bool directory)
    {
        // Attribute-only handles do not participate in Windows sharing checks.
        // Include FILE_LIST_DIRECTORY so denying write/delete also prevents a
        // checked directory from being replaced while an operation uses its path.
        var handle = CreateFileW(path, directory ? 0x81u : 0x80000000u, 1, 0, 3, 0x00200000u | (directory ? 0x02000000u : 0), 0);
        if (handle.IsInvalid) { handle.Dispose(); throw new IOException("This item is unavailable or cannot be safely shared.", new Win32Exception()); }
        if (GetFileType(handle) != 1 || !GetFileInformationByHandle(handle, out var info) || (info.Attributes & 0x400) != 0 ||
            ((info.Attributes & 0x10) != 0) != directory)
        { handle.Dispose(); throw new IOException("Symbolic links, junctions, and special files cannot be shared."); }
        return handle;
    }
    public void Dispose() { foreach (var handle in rootLocks) handle.Dispose(); rootLocks.Clear(); }
    [StructLayout(LayoutKind.Sequential)] private struct FileInfo
    {
        public uint Attributes, CreationLow, CreationHigh, AccessLow, AccessHigh, WriteLow, WriteHigh;
        public uint Volume, SizeHigh, SizeLow, Links, IndexHigh, IndexLow;
    }
    [StructLayout(LayoutKind.Sequential)] private struct RenameInfo
    { public uint Flags; public nint RootDirectory; public uint NameLength; public ushort Name; }
    [StructLayout(LayoutKind.Sequential)] private struct IoStatus
    { public nint Status; public nuint Information; }
    [DllImport("ntdll.dll")] private static extern int NtSetInformationFile(SafeFileHandle file, out IoStatus status, nint information, uint length, int informationClass);
    [DllImport("ntdll.dll")] private static extern uint RtlNtStatusToDosError(int status);
    [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    private static extern SafeFileHandle CreateFileW(string name, uint access, uint share, nint security, uint creation, uint flags, nint template);
    [DllImport("kernel32.dll", SetLastError = true)] private static extern bool GetFileInformationByHandle(SafeFileHandle file, out FileInfo info);
    [DllImport("kernel32.dll")] private static extern uint GetFileType(SafeFileHandle file);
}
