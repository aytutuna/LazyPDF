namespace LazyPDF.Core;

// The output intent, the XMP packet and /Info.
internal sealed partial class PdfAConversionRun
{
    private void SetOutputIntent()
    {
        PdfObject? keep = null;
        foreach (var item in _doc.Array(_doc.Catalog, "OutputIntents")?.Items.Take(16) ?? [])
        {
            if (_doc.Resolve(item) is PdfDictionary intent && _doc.Stream(intent, "DestOutputProfile") is { } profile && ProfileUsable(profile))
            {
                keep = item;
                break;
            }
        }
        if (keep is not null && _doc.Resolve(keep) is PdfDictionary kept)
        {
            kept["S"] = new PdfName("GTS_PDFA1");
            if (_doc.Resolve(kept["OutputConditionIdentifier"]) is not PdfString) kept["OutputConditionIdentifier"] = new PdfString("Custom"u8.ToArray(), isHex: false);
            _doc.Catalog["OutputIntents"] = new PdfArray([keep]);
            return;
        }
        var dictionary = new PdfDictionary();
        dictionary["N"] = new PdfNumber(3L);
        dictionary["Filter"] = new PdfName("FlateDecode");
        var profileReference = _doc.Add(new PdfStream(dictionary, PdfFilterEncoders.Flate(PdfASrgb.SrgbProfile)));
        _doc.Catalog["OutputIntents"] = new PdfArray([_doc.Add(PdfAPacket.OutputIntent(profileReference))]);
        Changed(PdfAText.IntentAdded);
    }

    private bool ProfileUsable(PdfStream profile)
    {
        try
        {
            return _doc.Integer(profile.Dictionary, "N") is (1 or 3 or 4) and var n
                && PdfAChecker.IccProblem(_doc.Data(profile, 32L << 20), (int)n, Part == 1 ? 2 : 4) is null;
        }
        catch (PdfReadException)
        {
            return false;
        }
    }

    private void SetMetadata()
    {
        var found = DocumentMetadata.Read(_doc);
        var meta = found with
        {
            Title = PdfAPacket.Strip(found.Title),
            Author = PdfAPacket.Strip(found.Author),
            Subject = PdfAPacket.Strip(found.Subject),
            Keywords = PdfAPacket.Strip(found.Keywords),
            Creator = PdfAPacket.Strip(found.Creator),
            Producer = PdfAPacket.Strip(found.Producer) ?? PdfAText.Producer,
            Created = found.Created ?? date,
            Modified = date,
        };

        var info = _doc.Info;
        if (info is null)
        {
            info = new PdfDictionary();
            _doc.Trailer["Info"] = _doc.Add(info);
        }
        void Put(string key, string? value)
        {
            if (value is null) info.Remove(key);
            else info[key] = PdfText.ToObject(value);
        }
        if (Part == 4)
        {
            foreach (var (key, _) in info.Entries.ToList())
            {
                if (key is not ("CreationDate" or "ModDate")) info.Remove(key);
            }
        }
        else
        {
            Put("Title", meta.Title);
            Put("Author", meta.Author);
            Put("Subject", meta.Subject);
            Put("Keywords", meta.Keywords);
            Put("Creator", meta.Creator);
            Put("Producer", meta.Producer);
        }
        info["CreationDate"] = new PdfString(System.Text.Encoding.ASCII.GetBytes(PdfDate.Format(meta.Created!.Value)), isHex: false);
        info["ModDate"] = new PdfString(System.Text.Encoding.ASCII.GetBytes(PdfDate.Format(date)), isHex: false);

        _meta = meta;
        PutPacket(declare: true);
        Changed(PdfAText.MetadataWritten(level));
    }

    // The packet names the level only for a file the validator passes: a file that says it is PDF/A and is not
    // is worse than one that makes no claim.
    private void PutPacket(bool declare)
    {
        var dictionary = new PdfDictionary();
        dictionary["Type"] = new PdfName("Metadata");
        dictionary["Subtype"] = new PdfName("XML");
        _doc.Catalog["Metadata"] = _doc.Add(new PdfStream(dictionary, PdfAPacket.Xmp(level, _meta!, date, declare)));
    }
}
