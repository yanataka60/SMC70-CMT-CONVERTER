program SMC70BIN2CMT_fixed11;

{$APPTYPE CONSOLE}

uses
  System.SysUtils,
  System.Classes;

const
  // ============================================================
  // WAV
  // ============================================================
  WAV_SAMPLE_RATE      = 48000;
  WAV_CHANNELS         = 1;
  WAV_BITS_PER_SAMPLE  = 8;

  // ============================================================
  // SMC-70 PWM
  // ============================================================
  // Nominal data symbols are fractional at 48 kHz.
  // 0       : 29.5 samples average (29/30)
  // 1       : 39.5 samples average (39/40)
  // Leader  : 66 samples (33H + 33L)
  // ============================================================
  PWM_ZERO_BASE        = 29;
  PWM_ONE_BASE         = 39;
  PWM_LEADER_SAMPLES   = 66;

  // ============================================================
  // Measured SMC-70 tape structure
  // ============================================================
  // WAV starts with 49,992 samples of LOW/silence.
  // 49,992 / 48,000 = 1.0415 sec
  // ============================================================
  INITIAL_SILENCE_SAMPLES = 49992;

  // Initial leader before standard label
  INITIAL_LEADER_PAIRS = 3128;

  // ============================================================
  // Gap between standard label and first record
  // ============================================================
  // Measured from the known-good test4.wav:
  // 3,481 pairs of ZERO symbols, followed by a 57-sample LOW
  // separator before the first 10-pair record leader.
  // ============================================================
  LABEL_TO_DATA_ZERO_PAIRS = 3481;
  LABEL_TO_DATA_SEPARATOR_SAMPLES = 57;

  // ============================================================
  // Data record
  // ============================================================
  RECORD_LEADER_PAIRS = 10;
  RECORD_DATA_SIZE = 128;

  // Measured source tape contains 1200 complete ZERO symbols after
  // the final record, then ONE FINAL HIGH HALF-SYMBOL followed by
  // 18 LOW samples.  The final high half is important: the known-good
  // tape does NOT end with a complete zero symbol.
  TRAILING_ZERO_PAIRS = 1200;
  TRAILING_END_HIGH_SAMPLES = 15;
  TRAILING_LOW_SAMPLES = 18;

  COMMAND_FLAG = $0000;


type
  TByteArray = array of Byte;


var
  WaveData: TBytes;
  ZeroPhase: Integer = 0;
  OnePhase: Integer = 0;


procedure ShowUsage;
begin
  Writeln;
  Writeln('SMC70BIN2CMT');
  Writeln('BIN -> SMC-70 CMT WAV converter');
  Writeln;
  Writeln('Usage:');
  Writeln('  SMC70BIN2CMT input.bin output.wav load execute file_id file_name');
  Writeln;
  Writeln('Example:');
  Writeln('  SMC70BIN2CMT test.bin test.wav 0100 0100 00 TEST');
  Writeln;
  Writeln('load    : 16-bit hexadecimal load address');
  Writeln('execute : 16-bit hexadecimal execute address');
  Writeln('file_id : 8-bit hexadecimal file ID (00-FF)');
  Writeln('        : 00   :BINARY');
  Writeln('        : 01   :BASIC Program');
  Writeln('        : 02   :BASIC DATA File');
  Writeln('        : 03   :BASIC LINK Module');
  Writeln('        : 04-FF:Reserved');
  Writeln;
end;


function ParseHexWord(const S: string; out Value: Word): Boolean;
var
  T: string;
  V: Integer;
begin
  Result := False;
  Value := 0;

  T := Trim(S);
  if T = '' then
    Exit;

  if T.StartsWith('$') then
    Delete(T, 1, 1)
  else if T.StartsWith('0x', True) then
    Delete(T, 1, 2);

  if T = '' then
    Exit;

  try
    V := StrToInt('$' + T);
    if (V < 0) or (V > $FFFF) then
      Exit;

    Value := Word(V);
    Result := True;
  except
    Result := False;
  end;
end;


function ParseHexByte(const S: string; out Value: Byte): Boolean;
var
  T: string;
  V: Integer;
begin
  Result := False;
  Value := 0;

  T := Trim(S);
  if T = '' then
    Exit;

  if T.StartsWith('$') then
    Delete(T, 1, 1)
  else if T.StartsWith('0x', True) then
    Delete(T, 1, 2);

  if T = '' then
    Exit;

  try
    V := StrToInt('$' + T);
    if (V < 0) or (V > $FF) then
      Exit;

    Value := Byte(V);
    Result := True;
  except
    Result := False;
  end;
end;


procedure ParseTapeFileName(
  const FileSpec: string;
  FileID: Byte;
  out Name8: string;
  out Type3: string
);
var
  S: string;
  P: Integer;
  NamePart: string;
  TypePart: string;
  HasDot: Boolean;
begin
  // SMC-70 tape label name/type rules:
  //
  //   TEST.BAS   -> NAME="TEST    ", TYPE="BAS"
  //   TEST       -> NAME="TEST    ", TYPE="   "
  //
  // If a dot exists, the text before the dot is the file name and
  // the text after the dot is the type name.  The file name is
  // truncated to 8 characters and the type name to 3 characters.
  // Text beyond those limits is discarded.
  //
  // If there is no dot, the entire string is the file name and the
  // type is filled with spaces.  Exception: File ID 01h uses BAS
  // as the type when there is no dot.
  S := ExtractFileName(FileSpec);
  S := UpperCase(S);

  NamePart := '';
  TypePart := '';
  HasDot := False;

  P := Pos('.', S);
  if P > 0 then
  begin
    HasDot := True;
    NamePart := Copy(S, 1, P - 1);
    TypePart := Copy(S, P + 1, MaxInt);
  end
  else
  begin
    NamePart := S;
  end;

  // File name: maximum 8 characters.
  if Length(NamePart) > 8 then
    NamePart := Copy(NamePart, 1, 8);

  // Type: maximum 3 characters.
  if Length(TypePart) > 3 then
    TypePart := Copy(TypePart, 1, 3);

  // No dot means type is normally all spaces.
  if not HasDot then
  begin
    if FileID = $01 then
      TypePart := 'BAS'
    else
      TypePart := '';
  end;

  while Length(NamePart) < 8 do
    NamePart := NamePart + ' ';

  while Length(TypePart) < 3 do
    TypePart := TypePart + ' ';

  Name8 := NamePart;
  Type3 := TypePart;
end;


procedure AddSamples(Value: Byte; Count: Integer);
var
  OldLen: Integer;
begin
  if Count <= 0 then
    Exit;

  OldLen := Length(WaveData);
  SetLength(WaveData, OldLen + Count);
  FillChar(WaveData[OldLen], Count, Value);
end;


procedure AddSymbol(SampleCount: Integer);
var
  HighCount: Integer;
  LowCount: Integer;
begin
  HighCount := SampleCount div 2;
  LowCount := SampleCount - HighCount;

  // SMC-70 waveform is HIGH first, then LOW.
  AddSamples(255, HighCount);
  AddSamples(0, LowCount);
end;


procedure AddInitialSilence;
begin
  AddSamples(0, INITIAL_SILENCE_SAMPLES);
end;


procedure AddLeader(Pairs: Integer);
var
  I: Integer;
begin
  for I := 1 to Pairs do
    AddSymbol(PWM_LEADER_SAMPLES);
end;


function NextZeroSamples: Integer;
begin
  // Average = 29.5 samples.  Alternate 29 and 30 samples.
  Result := PWM_ZERO_BASE;
  if ZeroPhase = 1 then
    Inc(Result);
  ZeroPhase := 1 - ZeroPhase;
end;


function NextOneSamples: Integer;
begin
  // Average = 39.5 samples.  Alternate 39 and 40 samples.
  Result := PWM_ONE_BASE;
  if OnePhase = 1 then
    Inc(Result);
  OnePhase := 1 - OnePhase;
end;


procedure AddZeroPairs(Pairs: Integer);
var
  I: Integer;
begin
  for I := 1 to Pairs do
    AddSymbol(NextZeroSamples);
end;


procedure AddHeader;
begin
  // One short zero symbol.
  AddSymbol(NextZeroSamples);
end;


procedure AddByte(Value: Byte);
var
  Bit: Integer;
begin
  // START = 0
  AddSymbol(NextZeroSamples);

  // DATA = B7..B0
  for Bit := 7 downto 0 do
  begin
    if (Value and (1 shl Bit)) <> 0 then
      AddSymbol(NextOneSamples)
    else
      AddSymbol(NextZeroSamples);
  end;

  // STOP = 0
  AddSymbol(NextZeroSamples);
end;


function MakeStandardLabel(
  LoadAddress: Word;
  ExecuteAddress: Word;
  DataLength: Word;
  FileID: Byte;
  const FileSpec: string
): TBytes;
var
  D: TBytes;
  I: Integer;
  CheckSum: Byte;
  Name8: string;
  Type3: string;
begin
  // 35-byte standard label
  //
  // 00       File ID
  // 01-08    File name
  // 09-11    File type / reserved
  // 12-13    Load address, little endian
  // 14-15    Execute address, little endian
  // 16-17    Data length, little endian
  // 18       Command
  // 19-31    Reserved / free area (13 bytes)
  // 32       XOR checksum
  // 33-34    Reserved

  SetLength(D, 35);
  for I := 0 to High(D) do
    D[I] := 0;

  D[0] := FileID;

  ParseTapeFileName(FileSpec, FileID, Name8, Type3);

  for I := 0 to 7 do
    D[1 + I] := Ord(Name8[I + 1]);

  for I := 0 to 2 do
    D[9 + I] := Ord(Type3[I + 1]);

  D[12] := Byte(LoadAddress and $FF);
  D[13] := Byte((LoadAddress shr 8) and $FF);

  D[14] := Byte(ExecuteAddress and $FF);
  D[15] := Byte((ExecuteAddress shr 8) and $FF);

  D[16] := Byte(DataLength and $FF);
  D[17] := Byte((DataLength shr 8) and $FF);

  D[18] := Byte(COMMAND_FLAG and $FF);

  for I := 19 to 34 do
    D[I] := 0;

  // File ID 01h special reserved/free-area data.
  // The 13 bytes are stored contiguously at D[19]..D[31].
  // D[32] is the XOR checksum and is not part of this sequence.
  if FileID = $01 then
  begin
    D[19] := $00;
    D[20] := $49;
    D[21] := $B1;
    D[22] := $79;
    D[23] := $00;
    D[24] := $01;
    D[25] := $00;
    D[26] := $00;
    D[27] := $00;
    D[28] := $00;
    D[29] := $31;
    D[30] := $01;
    D[31] := $01;
  end;

  // The actual SMC-70 standard label places the XOR checksum
  // at byte 32. It is calculated after the special free area has
  // been installed.
  CheckSum := 0;
  for I := 0 to 31 do
    CheckSum := CheckSum xor D[I];

  D[32] := CheckSum;
  D[34] := 0;

  Result := D;
end;


procedure AddLabel(const LabelData: TBytes);
var
  I: Integer;
begin
  for I := 0 to High(LabelData) do
    AddByte(LabelData[I]);
end;


function CalculateXOR(
  const Data: TBytes;
  StartIndex: Integer;
  Count: Integer
): Byte;
var
  I: Integer;
begin
  Result := 0;

  for I := 0 to Count - 1 do
    Result := Result xor Data[StartIndex + I];
end;


procedure AddRecord(
  const Data: TBytes;
  StartIndex: Integer;
  Count: Integer
);
var
  I: Integer;
  CheckSum: Byte;
begin
  // Record structure:
  //   10 leader pairs
  //   1 short header symbol
  //   exactly 128 data bytes
  //   XOR checksum byte
  //
  // A short final record is padded with 00h on tape.  The file
  // length in the standard label remains the actual BIN length.
  // Thus a 775-byte file is recorded as 6 x 128 bytes plus a
  // final 128-byte record containing 7 data bytes and 121 zeroes.

  AddLeader(RECORD_LEADER_PAIRS);
  AddHeader;

  CheckSum := 0;

  for I := 0 to RECORD_DATA_SIZE - 1 do
  begin
    if I < Count then
    begin
      AddByte(Data[StartIndex + I]);
      CheckSum := CheckSum xor Data[StartIndex + I];
    end
    else
    begin
      AddByte(0);
      CheckSum := CheckSum xor 0;
    end;
  end;

  AddByte(CheckSum);
end;


procedure AddTrailingEnd;
begin
  // Exact end shape measured from the known-good test4(4).wav:
  // after the 1200 complete ZERO symbols, the waveform has one
  // final HIGH half-symbol (15 samples) and then 18 LOW samples.
  // Do NOT use AddSymbol here; that would add an unwanted 14/15
  // sample LOW half and prevent the SMC-70 from seeing the end.
  AddSamples(255, TRAILING_END_HIGH_SAMPLES);
  AddSamples(0, TRAILING_LOW_SAMPLES);
end;


procedure WriteWordLE(Stream: TStream; Value: Word);
begin
  Stream.WriteBuffer(Value, SizeOf(Value));
end;


procedure WriteDWordLE(Stream: TStream; Value: Cardinal);
begin
  Stream.WriteBuffer(Value, SizeOf(Value));
end;


procedure WriteWAV(
  const FileName: string;
  const Samples: TBytes
);
var
  FS: TFileStream;
  FileSize: Cardinal;
  DataSize: Cardinal;
  ByteRate: Cardinal;
  BlockAlign: Word;
  AudioFormat: Word;
  NumChannels: Word;
  SampleRate: Cardinal;
  BitsPerSample: Word;
begin
  FS := TFileStream.Create(
    FileName,
    fmCreate or fmShareDenyWrite
  );

  try
    AudioFormat := 1;
    NumChannels := WAV_CHANNELS;
    SampleRate := WAV_SAMPLE_RATE;
    BitsPerSample := WAV_BITS_PER_SAMPLE;

    BlockAlign := NumChannels * (BitsPerSample div 8);
    ByteRate := SampleRate * BlockAlign;
    DataSize := Length(Samples);

    FileSize := 4 + 8 + 16 + 8 + DataSize;

    FS.WriteBuffer(PAnsiChar('RIFF')^, 4);
    WriteDWordLE(FS, FileSize);
    FS.WriteBuffer(PAnsiChar('WAVE')^, 4);

    FS.WriteBuffer(PAnsiChar('fmt ')^, 4);
    WriteDWordLE(FS, 16);
    WriteWordLE(FS, AudioFormat);
    WriteWordLE(FS, NumChannels);
    WriteDWordLE(FS, SampleRate);
    WriteDWordLE(FS, ByteRate);
    WriteWordLE(FS, BlockAlign);
    WriteWordLE(FS, BitsPerSample);

    FS.WriteBuffer(PAnsiChar('data')^, 4);
    WriteDWordLE(FS, DataSize);

    if DataSize > 0 then
      FS.WriteBuffer(Samples[0], DataSize);
  finally
    FS.Free;
  end;
end;


function ReadBinaryFile(const FileName: string): TBytes;
var
  FS: TFileStream;
  Size: Int64;
begin
  FS := TFileStream.Create(
    FileName,
    fmOpenRead or fmShareDenyWrite
  );

  try
    Size := FS.Size;

    if Size <= 0 then
      raise Exception.Create('BIN file is empty.');

    if Size > $FFFF then
      raise Exception.Create(
        'BIN file is too large. Maximum size is 65535 bytes.'
      );

    SetLength(Result, Size);
    FS.ReadBuffer(Result[0], Size);
  finally
    FS.Free;
  end;
end;


procedure BuildCMT(
  const BinData: TBytes;
  LoadAddress: Word;
  ExecuteAddress: Word;
  FileID: Byte;
  const TapeFileName: string
);
var
  LabelData: TBytes;
  Pos: Integer;
  Count: Integer;
  RecordNo: Integer;
begin
  SetLength(WaveData, 0);
  ZeroPhase := 0;
  OnePhase := 0;

  // ============================================================
  // 1. Initial silence
  // ============================================================
  {Writeln('Adding initial silence: ', INITIAL_SILENCE_SAMPLES,
    ' samples');
  }
  AddInitialSilence;

  // ============================================================
  // 2. Initial leader
  // ============================================================
  {Writeln('Adding initial leader: ', INITIAL_LEADER_PAIRS,
    ' pairs');
  }
  AddLeader(INITIAL_LEADER_PAIRS);

  // ============================================================
  // 3. Standard-label header
  // ============================================================
  //Writeln('Adding label header...');
  AddHeader;

  // ============================================================
  // 4. Standard label
  // ============================================================
  LabelData := MakeStandardLabel(
    LoadAddress,
    ExecuteAddress,
    Word(Length(BinData)),
    FileID,
    TapeFileName
  );

  //Writeln('Adding standard label...');
  AddLabel(LabelData);

  // ============================================================
  // 5. Measured label-to-record area
  // ============================================================
  // IMPORTANT:
  // This is NOT another record leader.
  // It is the long zero-symbol area present in the known-good
  // SMC-70 test4.wav.
  // ============================================================
  {Writeln('Adding label-to-data zero area: ',
    LABEL_TO_DATA_ZERO_PAIRS, ' pairs');
  }
  AddZeroPairs(LABEL_TO_DATA_ZERO_PAIRS);

  {Writeln('Adding label-to-data separator: ',
    LABEL_TO_DATA_SEPARATOR_SAMPLES, ' LOW samples');
  }
  AddSamples(0, LABEL_TO_DATA_SEPARATOR_SAMPLES);

  // ============================================================
  // 6. Data records
  // ============================================================
  Pos := 0;
  RecordNo := 0;

  while Pos < Length(BinData) do
  begin
    Inc(RecordNo);

    Count := Length(BinData) - Pos;
    if Count > RECORD_DATA_SIZE then
      Count := RECORD_DATA_SIZE;

{    Writeln(
      Format(
        'Adding record %d: offset=%04Xh size=%d',
        [RecordNo, Pos, Count]
      )
    );
}
    AddRecord(BinData, Pos, Count);

    Inc(Pos, Count);
  end;

  // ============================================================
  // 7. Measured trailing ZERO-symbol area
  // ============================================================
  {Writeln('Adding trailing zero area: ',
    TRAILING_ZERO_PAIRS, ' symbols');
  }
  AddZeroPairs(TRAILING_ZERO_PAIRS);

  // 8. Exact measured end-of-tape pattern
  // ============================================================
  {Writeln('Adding final HIGH half-symbol: ',
    TRAILING_END_HIGH_SAMPLES, ' samples');
  Writeln('Adding final LOW: ', TRAILING_LOW_SAMPLES, ' samples');
  }
  AddTrailingEnd;

  Writeln;
  Writeln('WAV samples: ', Length(WaveData));
  Writeln('WAV duration: ',
    FormatFloat('0.000000',
      Length(WaveData) / WAV_SAMPLE_RATE),
    ' sec');
end;


procedure Main;
var
  InputFile: string;
  OutputFile: string;
  LoadAddress: Word;
  ExecuteAddress: Word;
  FileID: Byte;
  TapeFileName: string;
  LabelName8: string;
  LabelType3: string;
  BinData: TBytes;
begin
  Writeln('========================================');
  Writeln(' SMC70BIN2CMT');
  Writeln(' BIN -> SMC-70 CMT WAV');
  Writeln('========================================');
  Writeln;

  if ParamCount <> 6 then
  begin
    ShowUsage;
    ExitCode := 1;
    Exit;
  end;

  InputFile := ParamStr(1);
  OutputFile := ParamStr(2);
  TapeFileName := ParamStr(6);

  if not ParseHexWord(ParamStr(3), LoadAddress) then
  begin
    Writeln('ERROR: Invalid load address: ', ParamStr(3));
    ExitCode := 1;
    Exit;
  end;

  if not ParseHexWord(ParamStr(4), ExecuteAddress) then
  begin
    Writeln('ERROR: Invalid execute address: ', ParamStr(4));
    ExitCode := 1;
    Exit;
  end;

  if not ParseHexByte(ParamStr(5), FileID) then
  begin
    Writeln('ERROR: Invalid file ID: ', ParamStr(5));
    ExitCode := 1;
    Exit;
  end;

  if not FileExists(InputFile) then
  begin
    Writeln('ERROR: Input file not found: ', InputFile);
    ExitCode := 1;
    Exit;
  end;

  try
    Writeln('Input file   : ', InputFile);
    Writeln('Output file  : ', OutputFile);
    Writeln('Load address : ', IntToHex(LoadAddress, 4), 'h');
    Writeln('Execute      : ', IntToHex(ExecuteAddress, 4), 'h');
    Writeln('File ID      : ', IntToHex(FileID, 2), 'h');
    Writeln('Tape name    : ', TapeFileName);

    // Show the actual 8+3 fields that will be written to the label.
    ParseTapeFileName(TapeFileName, FileID, LabelName8, LabelType3);
    Writeln('  File name  : [', LabelName8, ']');
    Writeln('  File type  : [', LabelType3, ']');
    if FileID = $01 then
      Writeln('  File ID 01 free area: 00 49 B1 79 00 01 00 00 00 00 31 01 01');

    BinData := ReadBinaryFile(InputFile);

    Writeln('Data length  : ',
      IntToHex(Length(BinData), 4),
      'h (', Length(BinData), ' bytes)');
    Writeln;

    BuildCMT(
      BinData,
      LoadAddress,
      ExecuteAddress,
      FileID,
      TapeFileName
    );

    Writeln;
    Writeln('Writing WAV...');

    WriteWAV(OutputFile, WaveData);

    Writeln;
    Writeln('Completed successfully.');
    Writeln('Output: ', OutputFile);

    ExitCode := 0;
  except
    on E: Exception do
    begin
      Writeln;
      Writeln('ERROR: ', E.ClassName, ': ', E.Message);
      ExitCode := 1;
    end;
  end;
end;


begin
  Main;
end.

