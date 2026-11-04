namespace LazyPDF.Core;

/// <summary>Glyph name tables fixed by the font specs: CFF standard strings, the Macintosh glyph order of 'post', StandardEncoding.</summary>
internal static class StandardNames
{
    /// <summary>The 391 standard strings, SID 0 to 390 (Adobe TN 5176, Appendix A).</summary>
    public static readonly string[] CffStrings = (
        ".notdef space exclam quotedbl numbersign dollar percent ampersand quoteright parenleft parenright asterisk plus comma hyphen period slash " +
        "zero one two three four five six seven eight nine colon semicolon less equal greater question at " +
        "A B C D E F G H I J K L M N O P Q R S T U V W X Y Z bracketleft backslash bracketright asciicircum underscore quoteleft " +
        "a b c d e f g h i j k l m n o p q r s t u v w x y z braceleft bar braceright asciitilde " +
        "exclamdown cent sterling fraction yen florin section currency quotesingle quotedblleft guillemotleft guilsinglleft guilsinglright fi fl " +
        "endash dagger daggerdbl periodcentered paragraph bullet quotesinglbase quotedblbase quotedblright guillemotright ellipsis perthousand questiondown " +
        "grave acute circumflex tilde macron breve dotaccent dieresis ring cedilla hungarumlaut ogonek caron emdash " +
        "AE ordfeminine Lslash Oslash OE ordmasculine ae dotlessi lslash oslash oe germandbls " +
        "onesuperior logicalnot mu trademark Eth onehalf plusminus Thorn onequarter divide brokenbar degree thorn threequarters twosuperior registered minus eth multiply threesuperior copyright " +
        "Aacute Acircumflex Adieresis Agrave Aring Atilde Ccedilla Eacute Ecircumflex Edieresis Egrave Iacute Icircumflex Idieresis Igrave Ntilde " +
        "Oacute Ocircumflex Odieresis Ograve Otilde Scaron Uacute Ucircumflex Udieresis Ugrave Yacute Ydieresis Zcaron " +
        "aacute acircumflex adieresis agrave aring atilde ccedilla eacute ecircumflex edieresis egrave iacute icircumflex idieresis igrave ntilde " +
        "oacute ocircumflex odieresis ograve otilde scaron uacute ucircumflex udieresis ugrave yacute ydieresis zcaron " +
        "exclamsmall Hungarumlautsmall dollaroldstyle dollarsuperior ampersandsmall Acutesmall parenleftsuperior parenrightsuperior twodotenleader onedotenleader " +
        "zerooldstyle oneoldstyle twooldstyle threeoldstyle fouroldstyle fiveoldstyle sixoldstyle sevenoldstyle eightoldstyle nineoldstyle " +
        "commasuperior threequartersemdash periodsuperior questionsmall asuperior bsuperior centsuperior dsuperior esuperior isuperior lsuperior msuperior nsuperior osuperior rsuperior ssuperior tsuperior " +
        "ff ffi ffl parenleftinferior parenrightinferior Circumflexsmall hyphensuperior Gravesmall " +
        "Asmall Bsmall Csmall Dsmall Esmall Fsmall Gsmall Hsmall Ismall Jsmall Ksmall Lsmall Msmall Nsmall Osmall Psmall Qsmall Rsmall Ssmall Tsmall Usmall Vsmall Wsmall Xsmall Ysmall Zsmall " +
        "colonmonetary onefitted rupiah Tildesmall exclamdownsmall centoldstyle Lslashsmall Scaronsmall Zcaronsmall Dieresissmall Brevesmall Caronsmall Dotaccentsmall Macronsmall " +
        "figuredash hypheninferior Ogoneksmall Ringsmall Cedillasmall questiondownsmall oneeighth threeeighths fiveeighths seveneighths onethird twothirds " +
        "zerosuperior foursuperior fivesuperior sixsuperior sevensuperior eightsuperior ninesuperior " +
        "zeroinferior oneinferior twoinferior threeinferior fourinferior fiveinferior sixinferior seveninferior eightinferior nineinferior " +
        "centinferior dollarinferior periodinferior commainferior " +
        "Agravesmall Aacutesmall Acircumflexsmall Atildesmall Adieresissmall Aringsmall AEsmall Ccedillasmall Egravesmall Eacutesmall Ecircumflexsmall Edieresissmall " +
        "Igravesmall Iacutesmall Icircumflexsmall Idieresissmall Ethsmall Ntildesmall Ogravesmall Oacutesmall Ocircumflexsmall Otildesmall Odieresissmall OEsmall Oslashsmall " +
        "Ugravesmall Uacutesmall Ucircumflexsmall Udieresissmall Yacutesmall Thornsmall Ydieresissmall " +
        "001.000 001.001 001.002 001.003 Black Bold Book Light Medium Regular Roman Semibold").Split(' ');

    /// <summary>The 258 glyph names an index of 'post' format 1 and 2 refers to (Apple's TrueType reference manual).</summary>
    public static readonly string[] MacGlyphs = (
        ".notdef .null nonmarkingreturn space exclam quotedbl numbersign dollar percent ampersand quotesingle parenleft parenright asterisk plus comma hyphen period slash " +
        "zero one two three four five six seven eight nine colon semicolon less equal greater question at " +
        "A B C D E F G H I J K L M N O P Q R S T U V W X Y Z bracketleft backslash bracketright asciicircum underscore grave " +
        "a b c d e f g h i j k l m n o p q r s t u v w x y z braceleft bar braceright asciitilde " +
        "Adieresis Aring Ccedilla Eacute Ntilde Odieresis Udieresis aacute agrave acircumflex adieresis atilde aring ccedilla eacute egrave ecircumflex edieresis " +
        "iacute igrave icircumflex idieresis ntilde oacute ograve ocircumflex odieresis otilde uacute ugrave ucircumflex udieresis " +
        "dagger degree cent sterling section bullet paragraph germandbls registered copyright trademark acute dieresis notequal AE Oslash " +
        "infinity plusminus lessequal greaterequal yen mu partialdiff summation product pi integral ordfeminine ordmasculine Omega ae oslash " +
        "questiondown exclamdown logicalnot radical florin approxequal Delta guillemotleft guillemotright ellipsis nonbreakingspace Agrave Atilde Otilde OE oe " +
        "endash emdash quotedblleft quotedblright quoteleft quoteright divide lozenge ydieresis Ydieresis fraction currency guilsinglleft guilsinglright fi fl " +
        "daggerdbl periodcentered quotesinglbase quotedblbase perthousand Acircumflex Ecircumflex Aacute Edieresis Egrave Iacute Icircumflex Idieresis Igrave " +
        "Oacute Ocircumflex apple Ograve Uacute Ucircumflex Ugrave dotlessi circumflex tilde macron breve dotaccent ring cedilla hungarumlaut ogonek caron " +
        "Lslash lslash Scaron scaron Zcaron zcaron brokenbar Eth eth Yacute yacute Thorn thorn minus multiply onesuperior twosuperior threesuperior " +
        "onehalf onequarter threequarters franc Gbreve gbreve Idotaccent Scedilla scedilla Cacute cacute Ccaron ccaron dcroat").Split(' ');

    /// <summary>StandardEncoding as the name of each code, null where the code is unassigned.</summary>
    public static readonly string?[] StandardEncoding = BuildStandardEncoding();

    /// <summary>Standard strings that give a name to a code in StandardEncoding: the SID of each code, 0 where none.</summary>
    public static readonly int[] StandardEncodingSids = BuildStandardSids();

    private static int[] BuildStandardSids()
    {
        var sids = new int[256];
        Range(32, 126, 1);
        Range(161, 175, 96);
        Range(177, 180, 111);
        Range(182, 189, 115);
        sids[191] = 123;
        Range(193, 200, 124);
        sids[202] = 132;
        sids[203] = 133;
        Range(205, 208, 134);
        sids[225] = 138;
        sids[227] = 139;
        Range(232, 235, 140);
        sids[241] = 144;
        sids[245] = 145;
        Range(248, 251, 146);
        return sids;

        void Range(int from, int to, int sid)
        {
            for (var c = from; c <= to; c++) sids[c] = sid + c - from;
        }
    }

    private static string?[] BuildStandardEncoding()
    {
        var sids = BuildStandardSids();
        var names = new string?[256];
        for (var c = 0; c < 256; c++)
            if (sids[c] != 0) names[c] = CffStrings[sids[c]];
        return names;
    }
}
