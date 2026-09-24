// Copyright 2026 TidyVNC contributors. Licensed under GPL-2.0-or-later.
using TidyVNC.Native.Documents;

namespace TidyVNC.Native;

/// <summary>Connection-file messages (macOS NativeDocumentFailure and NativeDocumentOpenError descriptions).</summary>
public static class NativeDocumentTexts
{
    public static NativeText TopologyChanged { get; } = new("document.the.display.arrangement.changed.review.the.file.s.monitor.selection.again");
    public static NativeText Cancelled { get; } = Text(NativeDocumentOpenError.Cancelled);

    public static NativeText Text(NativeDocumentOpenError error) => new(error switch
    {
        NativeDocumentOpenError.NotRegular => "document.select.a.regular.connection.file",
        NativeDocumentOpenError.TooLarge => "document.the.connection.file.exceeds.the.1.mib.limit",
        NativeDocumentOpenError.Changed => "document.the.connection.file.changed.while.being.read.retry.to.review.its.current",
        NativeDocumentOpenError.Cancelled => "document.opening.the.connection.file.was.cancelled",
        _ => "document.the.connection.file.could.not.be.read.check.its.location.and.access",
    });

    public static NativeText Text(NativeDocumentFailure failure)
    {
        var message = new NativeText(failure.Problem switch
        {
            NativeDocumentProblem.Empty => "document.the.connection.file.is.empty",
            NativeDocumentProblem.InvalidHeader => "document.the.connection.file.header.is.unsupported",
            NativeDocumentProblem.NullByte => "document.the.connection.file.contains.a.null.byte",
            NativeDocumentProblem.LineTooLong => "document.a.connection.file.line.exceeds.its.byte.limit",
            NativeDocumentProblem.InvalidAssignment => "document.a.connection.file.assignment.is.malformed",
            NativeDocumentProblem.InvalidEscape => "document.a.connection.file.value.contains.an.invalid.escape",
            NativeDocumentProblem.TooLarge => "document.the.connection.file.exceeds.its.size.limit",
            NativeDocumentProblem.TooManyEntries => "document.the.connection.file.contains.too.many.assignments",
            NativeDocumentProblem.InvalidExportName => "document.a.field.cannot.be.exported.to.a.connection.file",
            NativeDocumentProblem.InvalidText => "document.the.connection.file.is.not.valid.utf.8",
            NativeDocumentProblem.InvalidIndex => "document.the.connection.file.entry.does.not.exist",
            NativeDocumentProblem.Unavailable => "document.a.connection.file.option.is.unavailable.in.this.build",
            _ => "document.a.connection.file.option.has.an.invalid.value",
        });
        return failure.Line == 0 ? message : new NativeText("document.error.line", failure.Line, message);
    }
}
