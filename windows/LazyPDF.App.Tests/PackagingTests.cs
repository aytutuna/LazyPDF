using LazyPDF.App.Services;
using Microsoft.Win32;
using Xunit;

namespace LazyPDF.App.Tests;

// What changes in the Store package: how it is told apart, what the settings do about it, and where files go.
public sealed class PackagingTests
{
    [Fact]
    public void ThePackageCallAnswersTooSmallABufferOnlyInsideAPackage()
    {
        Assert.True(Packaging.IsPackageResult(122));
        Assert.False(Packaging.IsPackageResult(15700)); // APPMODEL_ERROR_NO_PACKAGE
        Assert.False(Packaging.IsPackageResult(0));
    }

    [Fact]
    public void TheTestHostIsNotPackaged() => Assert.False(Packaging.IsPackaged);

    [Fact]
    public void APackagedAppWritesNothingToTheUsersClasses()
    {
        bool before = FileAssociation.IsRegisteredForCurrentUser();
        Packaging.IsPackaged = true;
        try
        {
            Assert.False(FileAssociation.SetForCurrentUser(!before));
        }
        finally
        {
            Packaging.IsPackaged = false;
        }
        Assert.Equal(before, FileAssociation.IsRegisteredForCurrentUser());
    }

    [Fact]
    public void NothingIsKeptBesideTheExe()
    {
        string app = Path.GetFullPath(AppContext.BaseDirectory);
        foreach (string folder in new[] { StoreFiles.DefaultDirectory, AppFolders.Recovery, AppFolders.Thumbnails, AppFolders.PrintCopies, AppFolders.OpenedAttachments })
            Assert.False(Path.GetFullPath(folder).StartsWith(app, StringComparison.OrdinalIgnoreCase), folder);
    }

    [Fact]
    public void FilesForOtherProgramsGoToTheTempFolderWhichThePackageDoesNotRedirect()
    {
        string temp = Path.GetFullPath(Path.GetTempPath());
        Assert.StartsWith(temp, Path.GetFullPath(AppFolders.PrintCopies), StringComparison.OrdinalIgnoreCase);
        Assert.StartsWith(temp, Path.GetFullPath(AppFolders.OpenedAttachments), StringComparison.OrdinalIgnoreCase);
    }

    [Fact]
    public void ThePackagedAppNamesTheSameAddressAndPipeAsTheUnpackagedOne()
    {
        // The manifest does not register lazypdf:, but an address given as the argument still opens its file.
        Assert.Equal("lazypdf", LazyPdfAddress.Scheme);
        var files = App.FilesOf([@"lazypdf://open?file=C%3A%5Cdocs%5Ca.pdf"]);
        Assert.Equal([@"C:\docs\a.pdf"], files);
    }
}

public sealed class AppInfoTests
{
    [Fact]
    public void TheVersionIsTheOneInTheBuildProps() => Assert.Equal("1.0.0", AppInfo.Version);

    [Fact]
    public void TheCopyrightIsTheLicenceLine() => Assert.Equal("Copyright (c) 2026 Aytu", AppInfo.Copyright);

    [Fact]
    public void TheNoticesFileIsShippedBesideTheExe()
    {
        string notices = Assert.IsType<string>(AppInfo.Notices());

        Assert.Contains("Lazy PDF third-party notices", notices);
        Assert.DoesNotContain("Not established", notices);
        Assert.Contains("Redistribution and use in source and binary forms", notices);
        Assert.Contains("AFM files", notices);
    }

    [Fact]
    public void AMissingNoticesFileReadsAsNull() => Assert.Null(AppInfo.Notices(Path.Combine(Path.GetTempPath(), Guid.NewGuid().ToString("N"))));
}

public sealed class SisterAppsTests
{
    // The question Windows is asked for an app from the Store, whose address is not under the classes key.
    [Fact]
    public void WindowsAnswersForAnAddressSomethingHandles() => Assert.True(SisterApps.Handled("ms-settings"));

    [Fact]
    public void WindowsAnswersNoForAnAddressNothingHandles() => Assert.False(SisterApps.Handled("lazypdf-test-nothing-handles-this"));
}
