{$I Defines.inc}

{-$Define bOwnRotate}
{$Define bTracePvd}

unit ReviewGDIPlus;

{******************************************************************************}
{* (c) 2013 Max Rusov                                                         *}
{*                                                                            *}
{* Review                                                                     *}
{* Image Viewer Plugn for Far 2/3                                             *}
{******************************************************************************}

interface

  uses
    Windows,
    ActiveX,
    MixTypes,
    MixUtils,
    MixStrings,
    MixClasses,
    MixWinUtils,

    GDIPAPI,
    GDIPOBJ,
    GDIImageUtil,
    PVApi,

    ReviewConst,
    ReviewDecoders;


  const
    cGDIPlusFormats = 'JPG,JPEG,JPE,PNG,GIF,TIF,TIFF,EXIF,BMP,DIB'; // EMF,WMF;

  const
    cThumbSize         = 128;           { ������ ������������ ������ }

  var
    DecodeWaitDelay   :Integer = 2000;  { ������� ���� �������������, ������ ��� �������� �����. ������ ��� ������ ��������. }
    StretchDelay      :Integer = 500;   { �������� ��� ��������������� }
    FastListDelay     :Integer = 500;   { ������ ����� ���������������, �� �������� ������������ ������� �������������� }
    ThumbDelay        :Integer = 250;   { �������� �� ������ ������������� ��� �������������� }

    optRotateOnEXIF   :Boolean = True;  { �������������� ������� �� ������ ���������� �� EXIF }
    optUseThumbnail   :Boolean = True;  { ������������ ������ ��� �������� �������� }
    optUseWinSize     :Boolean = True;  { ������������ ��� ������ ���� }
    optKeepDateOnSave :Boolean = True;  { ��������� ���� ��� ������������� }


  type
    TReviewGDIDecoder = class(TReviewDecoder)
    public
      constructor Create; override;
      destructor Destroy; override;

      function NeedPrecache :boolean; override;
      procedure ResetSettings; override;
      function GetState :TDecoderState; override;
      function CanWork(aLoad :Boolean) :boolean; override;

      { ������� ������������� }
      function pvdFileOpen(AImage :TReviewImageRec) :Boolean; override;
      function pvdGetPageInfo(AImage :TReviewImageRec) :Boolean; override;
      function pvdPageDecode(AImage :TReviewImageRec; ABkColor :Integer; AWidth, AHeight :Integer; ACache :Boolean) :Boolean; override;
      procedure pvdPageFree(AImage :TReviewImageRec); override;
      procedure pvdFileClose(AImage :TReviewImageRec); override;

      function pvdTagInfo(AImage :TReviewImageRec; aCode :Integer; var aType :Integer; var aValue :Pointer) :Boolean; override;

      { ������������ ������� }
//    function GetBitmapDC(AImage :TReviewImageRec; var ACX, ACY :Integer) :HDC; override;
      function GetBitmapHandle(AImage :TReviewImageRec; var aIsThumbnail :Boolean) :HBitmap; override;
      function Idle(AImage :TReviewImageRec; ACX, ACY :Integer) :boolean; override;
      function Save(AImage :TReviewImageRec; const ANewName, AFmtName :TString; aOrient, aQuality :Integer; aOptions :TSaveOptions) :Boolean; override;

    private
      FLastDecode :DWORD;
    end;


  function TryLockGDIPlus :Boolean;
  procedure UnlockGDIPlus;


{******************************************************************************}
{******************************} implementation {******************************}
{******************************************************************************}

  uses
    MixDebug;

 {-----------------------------------------------------------------------------}
 {                                                                             }
 {-----------------------------------------------------------------------------}

  const
    strFileNotFound       = 'File not found: %s';
    strNoEncoderFor       = 'No encoder for %s';
    strReadImageError     = 'Read image error';
    strLossyRotation      = 'Rotation is a lossy. Ctrl+F2 to confirm.';
    strCantSaveFrames     = 'Can''t save mutliframe image';


  procedure CorrectBoundEx(var ASize :TSize; const ALimit :TSize);
  var
    vScale :TFloat;
  begin
    if (ASize.cx > ALimit.cx) or (ASize.cy > ALimit.cy) then begin
      vScale := FloatMin( ALimit.cx / ASize.cx, ALimit.cy / ASize.cy);
      ASize.cx := Round(ASize.cx * vScale);
      ASize.cy := Round(ASize.cy * vScale);
    end;
  end;



  procedure RotateImage(AImage :TGPImage; AOrient :Integer);
  begin
    if AOrient <> 0 then begin
      case AOrient of
        3: AImage.RotateFlip(Rotate180FlipNone);
        6: AImage.RotateFlip(Rotate90FlipNone);
        8: AImage.RotateFlip(Rotate270FlipNone);

        2: AImage.RotateFlip(RotateNoneFlipX);
        4: AImage.RotateFlip(RotateNoneFlipY);
        5: AImage.RotateFlip(Rotate90FlipX);
        7: AImage.RotateFlip(Rotate270FlipX);
      end;
    end;
  end;


 {-----------------------------------------------------------------------------}
 { TGPImageEx                                                                  }
 {-----------------------------------------------------------------------------}

  type
    TGPImageEx = class(TGPImage)
//  TGPImageEx = class(TGPBitmap)
    public
      function _AddRef :Integer;
      function _Release :Integer;

      function GetImageSize :TSize;

      function Clone :TGPImageEx;

    private
      FRefCount :Integer;
    end;


  function TGPImageEx._AddRef :Integer;
  begin
    Result := InterlockedIncrement(FRefCount);
  end;


  function TGPImageEx._Release :Integer;
  begin
    Result := InterlockedDecrement(FRefCount);
    if Result = 0 then
      Destroy;
  end;


  function TGPImageEx.GetImageSize :TSize;
  begin
    Result := Size(GetWidth, GetHeight);
  end;


  function TGPImageEx.Clone :TGPImageEx;
  var
    cloneimage: GpImage;
  begin
    cloneimage := nil;
    SetStatus(GdipCloneImage(nativeImage, cloneimage));
    result := TGPImageEx.Create(cloneimage, lastResult);
  end;


 {-----------------------------------------------------------------------------}
 { TThumbnailThread                                                            }
 {-----------------------------------------------------------------------------}

  var
    { GDIPlus �� ������������ ������������� ������. ���������� ����������� ������, }
    { �����, �� �����������, �������� ����������... }
    GDIPlusCS :TRTLCriticalSection;


  function TryLockGDIPlus :Boolean;
  begin
    Result := TryEnterCriticalSection(GDIPlusCS);
  end;

  procedure UnlockGDIPlus;
  begin
    LeaveCriticalSection(GDIPlusCS);
  end;



  type
    TTaskState = (
      tsNew,
      tsProceed,
      tsReady,
      tsCancelled
    );

    TTask = class(TBasis)
    public
      constructor CreateEx(AImage :TGPImageEx; const AName :TString; AFrame :Integer; const ASize :TSize);
      destructor Destroy; override;

      function _AddRef :Integer;
      function _Release :Integer;

    private
      FRefCount   :Integer;
      FImage      :TGPImageEx;
      FName       :TString;
      FFrame      :Integer;
      FSize       :TSize;
      FThumb      :TMemDC;
      FState      :TTaskState;
      FError      :TString;
      FOnTask     :TNotifyEvent;
      FNext       :TTask;
    end;


  constructor TTask.CreateEx(AImage :TGPImageEx; const AName :TString; AFrame :Integer; const ASize :TSize);
  begin
    inherited Create;
    FImage := AImage;
    if FImage <> nil then
      FImage._AddRef;  
    FName  := AName;
    FFrame := AFrame;
    FSize  := ASize;
  end;


  destructor TTask.Destroy; {override;}
  begin
    if FImage <> nil then begin
      FImage._Release;
      FImage := nil;
    end;
    FreeObj(FThumb);
    inherited Destroy;
  end;


  function TTask._AddRef :Integer;
  begin
    Result := InterlockedIncrement(FRefCount);
  end;


  function TTask._Release :Integer;
  begin
    Result := InterlockedDecrement(FRefCount);
    if Result = 0 then
      Destroy;
  end;



  type
    TThumbnailThread = class(TThread)
    public
      constructor Create;
      destructor Destroy; override;

      procedure Execute; override;

      procedure AddTask(ATask :TTask);
      function CheckTask(ATask :TTask) :Boolean;
      procedure CancelTask(ATask :TTask);

    private
      FEvent   :THandle;
      FTaskCS  :TRTLCriticalSection;
      FTask    :TTask;

      function DoTask :Boolean;
      procedure NextTask;
      procedure Render(ATask :TTask);
    end;


  constructor TThumbnailThread.Create;
  begin
    FEvent := CreateEvent(nil, True, False, nil);
    InitializeCriticalSection(FTaskCS);
    inherited Create(False);
  end;


  destructor TThumbnailThread.Destroy; {override;}
  begin
    while FTask <> nil do
      NextTask;
    CloseHandle(FEvent);
    DeleteCriticalSection(FTaskCS);
    inherited Destroy;
  end;


  procedure TThumbnailThread.Execute;
  var
    vRes :DWORD;
  begin
    while not Terminated do begin
      vRes := WaitForSingleObject(FEvent, 5000);
//    TraceF('WaitRes = %d', [Byte(vRes)]);
      if Terminated then
        break;

      if vRes = WAIT_OBJECT_0 then begin
        ResetEvent(FEvent);
        while DoTask do;
      end;
    end;
  end;


  function TThumbnailThread.DoTask :Boolean;
  begin
    Result := False;

    EnterCriticalSection(FTaskCS);
    try
      while (FTask <> nil) and (FTask.FState = tsCancelled) do
        NextTask;
      if FTask = nil then
        Exit;
      FTask.FState := tsProceed;
      if Assigned(FTask.FOnTask) then
        FTask.FOnTask(nil);
    finally
      LeaveCriticalSection(FTaskCS);
    end;

    Render(FTask);

    EnterCriticalSection(FTaskCS);
    try
      FTask.FState := tsReady;
      if Assigned(FTask.FOnTask) then
        FTask.FOnTask(nil);
      NextTask;
    finally
      LeaveCriticalSection(FTaskCS);
    end;

    Result := True;
  end;


  procedure TThumbnailThread.NextTask;
  var
    vTask :TTask;
  begin
    vTask := FTask;
    FTask := vTask.FNext;
    vTask.FNext := nil;
    vTask._Release;
  end;


  function ImageAbortProc(AData :Pointer) :BOOL; stdcall;
  begin
//  TraceF('ImageAbort. State: %d', [Byte(TTask(AData).FState)]);
    Result := TTask(AData).FState = tsCancelled;
   {$ifdef bTrace}
    if Result then
      Trace('!Canceled');
   {$endif bTrace}
  end;


  procedure TThumbnailThread.Render(ATask :TTask);
  var
    vImage    :TGPImageEx;
    vSize     :TSize;
    vThumb    :TMemDC;
    vGraphics :TGPGraphics;
(*  vDimID    :TGUID; *)
    vCallback :Pointer;
  begin
    try
      EnterCriticalSection(GDIPlusCS);
      try
        vThumb := nil;
        vSize := ATask.FSize;
        vImage := ATask.FImage;
        try
          if vImage = nil then begin
            vImage := TGPImageEx.Create(ATask.FName);
            if vImage.GetLastStatus <> OK then
              AppError(strReadImageError);
          end;

(*        if ATask.FFrame > 0 then begin
            FillChar(vDimID, SizeOf(vDimID), 0);
            if vImage.GetFrameDimensionsList(@vDimID, 1) = Ok then
              vImage.SelectActiveFrame(vDimID, ATask.FFrame);
          end;  *)

          vThumb := TMemDC.Create(vSize.CX, vSize.CY);

//        GradientFillRect(vThumb.FDC, Rect(0, 0, vSize.CX, vSize.CY), RandomColor, RandomColor, True);
//        if ATask.FBackColor <> -1 then
//          GradientFillRect(vThumb.DC, Rect(0, 0, vSize.CX, vSize.CY), ATask.FBackColor, ATask.FBackColor, True); 

          vGraphics := TGPGraphics.Create(vThumb.DC);
          try
            GDICheck(vGraphics.GetLastStatus);
//          vGraphics.SetCompositingMode(CompositingModeSourceCopy);
//          vGraphics.SetCompositingQuality(CompositingQualityHighSpeed);
//          vGraphics.SetSmoothingMode(SmoothingModeHighQuality);
            if ATask.FFrame > 0 then
              vGraphics.SetInterpolationMode(InterpolationModeHighQuality);

           {$ifdef bTrace}
            TraceBegF('Render %s, %d x %d (%d M)...', [ATask.FName, vSize.CX, vSize.CY, (vSize.CX * vSize.CY * 4) div (1024 * 1024)]);
           {$endif bTrace}

            vCallback := @ImageAbortProc;
            vGraphics.DrawImage(vImage, MakeRect(0, 0, vSize.CX, vSize.CY), 0, 0, vImage.GetWidth, vImage.GetHeight, UnitPixel, nil, ImageAbort(vCallback), ATask);
            GDICheck(vGraphics.GetLastStatus);

           {$ifdef bTrace}
            TraceEnd('  Ready');
           {$endif bTrace}

          finally
            FreeObj(vGraphics);
          end;

          ATask.FThumb := vThumb;
          vThumb := nil;

        finally
          if vImage <> ATask.FImage then
            FreeObj(vImage);
          FreeObj(vThumb);
        end;
      finally
        LeaveCriticalSection(GDIPlusCS);
      end;

    except
      on E :Exception do
        ATask.FError := E.Message;
    end;
  end;


  procedure TThumbnailThread.AddTask(ATask :TTask);
  var
    vTask :TTask;
  begin
    EnterCriticalSection(FTaskCS);
    try
      if FTask = nil then
        FTask := ATask
      else begin
        vTask := FTask;
        while vTask.FNext <> nil do
          vTask := vTask.FNext;
        vTask.FNext := ATask;
      end;
      ATask._AddRef;
    finally
      LeaveCriticalSection(FTaskCS);
    end;

    SetEvent(FEvent);
  end;


  function TThumbnailThread.CheckTask(ATask :TTask) :Boolean;
  begin
    EnterCriticalSection(FTaskCS);
    try
      Result := ATask.FState = tsReady;
    finally
      LeaveCriticalSection(FTaskCS);
    end;
  end;


  procedure TThumbnailThread.CancelTask(ATask :TTask);
  begin
    EnterCriticalSection(FTaskCS);
    try
      ATask.FState := tsCancelled;
      ATask.FOnTask := nil;
    finally
      LeaveCriticalSection(FTaskCS);
    end;
  end;


  var
    GThumbThread :TThumbnailThread;


  procedure InitThumbnailThread;
  begin
    if GThumbThread = nil then
      GThumbThread := TThumbnailThread.Create;
  end;


  procedure DoneThumbnailThread;
  begin
    if GThumbThread <> nil then begin
      GThumbThread.Terminate;
      SetEvent(GThumbThread.FEvent);
      GThumbThread.WaitFor;
      FreeObj(GThumbThread);
    end;
  end;


 {-----------------------------------------------------------------------------}
 { TView                                                                       }
 {-----------------------------------------------------------------------------}

  type
    PDelays = ^TDelays;
    TDelays = array[0..MaxInt div SizeOf(Integer) - 1] of Integer;

    TView = class(TBasis)
    public
      constructor Create; override;
      destructor Destroy; override;
      procedure SetSrcImage(AImage :TGPImageEx);
      procedure ReleaseSrcImage;
      procedure SetFrame(AIndex :Integer);

      function _AddRef :Integer;
      function _Release :Integer;

      function InitThumbnail(ADX, ADY :Integer) :Boolean;
      procedure DecodeImage(ADX, ADY :Integer);
      function SaveAs({const} ANewName, AFmtName :TString; aOrient, aQuality :Integer; aOptions :TSaveOptions) :Boolean;

    private
      FRefCount    :Integer;

      FSrcName     :TString;      { ��� ����� }
      FSrcImage    :TGPImageEx;   { �������� ����������� }
      FOrient0     :Integer;      { �������� ���������� }
      FImgSize0    :TSize;        { �������� ������ �������� (������� ��������) }
      FImgSize     :TSize;        { ������ �������� � ������ ���������� }
      FPixels      :Integer;      { ��������� (BPP) }
      FFmtID       :TGUID;
      FFmtName     :TString;
      FHasAlpha    :Boolean;      { �������������� ����������� }
      FDirectDraw  :Boolean;      { ������������� �����������, �� ���������� preview'��� }
      FBkColor     :Integer;

      FThumbImage  :TMemDC;       { �����������, ���������������� ��� Bitmap }
      FThumbSize   :TSize;        { ������ Preview'��� }
      FIsThumbnail :Boolean;      { ��� ������ (thumbnail) }
      FErrorMess   :TString;

      FResizeStart :DWORD;        { ��� ��������� �������� ������������� ��� ��������������� }
      FResizeSize  :TSize;

      { ��� ��������� ������������� �����������... }
      FFrames      :Integer;
      FFrame       :Integer;
      FDelCount    :Integer;
      FDelays      :PPropertyItem;
      FDimID       :TGUID;

      { ��������� ������� ������������ �������� }
      FAsyncTask   :TTask;
      FFirstShow   :DWORD;

      { ��� ��������� Tag-�� }
      FStrTag      :TString;
      FInt64Tag    :Int64;

      procedure InitImageInfo;
      procedure SetAsyncTask(const ASize :TSize);
      function CheckAsyncTask :Boolean;
      procedure CancelTask;
      procedure TaskEvent(ASender :Tobject);
      function TagInfo(aCode :Integer; var aType :Integer; var aValue :Pointer) :Boolean;
      function Idle(ACX, ACY :Integer) :Boolean;
    end;


  constructor TView.Create; {override;}
  begin
    inherited Create;
    FFrame := -1;
  end;


  destructor TView.Destroy; {override;}
  begin
//  TraceF('%p TView.Destroy', [Pointer(Self)]);

    CancelTask;
    FreeObj(FThumbImage);
    MemFree(FDelays);

    ReleaseSrcImage;
    inherited Destroy;
  end;


  procedure TView.ReleaseSrcImage;
  begin
    if FSrcImage <> nil then begin
      FSrcImage._Release;
      FSrcImage := nil;
    end;
  end;


  function TView._AddRef :Integer;
  begin
    Result := InterlockedIncrement(FRefCount);
  end;


  function TView._Release :Integer;
  begin
    Result := InterlockedDecrement(FRefCount);
    if Result = 0 then
      Destroy;
  end;


  procedure TView.SetSrcImage(AImage :TGPImageEx);
  var
    vOrient :Integer;
  begin
    FSrcImage := AImage;
    FSrcImage._AddRef;

//  TraceExifProps(FSrcImage);

    FOrient0 := 0;
    if optRotateOnEXIF then
      if GetTagValueAsInt(FSrcImage, PropertyTagOrientation, vOrient) and (vOrient >= 1) and (vOrient <= 8) then begin
//      TraceF('EXIF Orientation: %d', [vOrient]);
        FOrient0 := vOrient;
      end;

    InitImageInfo;
  end;


  procedure TView.InitImageInfo;
  begin
    FImgSize0 := FSrcImage.GetImageSize;
    FImgSize := FImgSize0;
    FPixels := GetPixelFormatSize(FSrcImage.GetPixelFormat);

    FSrcImage.GetRawFormat(FFmtID);
    FFmtName := GetImgFmtName(FFmtID);

    { ����������� �������������� }
    FHasAlpha := UINT(ImageFlagsHasAlpha) and FSrcImage.GetFlags <> 0;

    { ������������ ���������� ������� � �������������/��������������� ����������� }
    FFrames := GetFrameCount(FSrcImage, @FDimID, @Pointer(FDelays), @FDelCount);
    FSrcImage.getLastStatus;

    FDirectDraw := {FHasAlpha or} (FDelays <> nil);
  end;


  procedure TView.SetFrame(AIndex :Integer);
  begin
    AIndex := RangeLimit(AIndex, 0, FFrames - 1);
    if AIndex <> FFrame then begin
      if (FFrames > 1) and (AIndex < FFrames) then
        FSrcImage.SelectActiveFrame(FDimID, AIndex);

      FImgSize := FSrcImage.GetImageSize;
      FPixels  := GetPixelFormatSize(FSrcImage.GetPixelFormat);

      CancelTask;
      FreeObj(FThumbImage);
      FErrorMess := '';

      FFrame := AIndex;
    end;
  end;


  function TView.InitThumbnail(ADX, ADY :Integer) :Boolean;
  var
    vThmImage :TGPImage;
    vGraphics :TGPGraphics;
  begin
    Result := False;
    if not IsEqualGUID(FFmtID, ImageFormatJPEG) then
      { ������ �������������� ������(?) ��� JPEG... }
      Exit;

   {$ifdef bTrace}
    TraceBegF('GetThumbnail: %d x %d', [ADX, ADY]);
   {$endif bTrace}

    vThmImage := FSrcImage.GetThumbnailImage(ADX, ADY, nil, nil);
    if (vThmImage = nil) or (vThmImage.GetLastStatus <> Ok) then begin
      FreeObj(vThmImage);
      Exit;
    end;

    try
      FThumbSize.cx := vThmImage.GetWidth;
      FThumbSize.cy := vThmImage.GetHeight;
      FIsThumbnail := True;

      FThumbImage := TMemDC.Create(FThumbSize.cx, FThumbSize.cy);
      vGraphics := TGPGraphics.Create(FThumbImage.DC);
      try
        vGraphics.DrawImage(vThmImage, 0, 0, FThumbSize.cx, FThumbSize.cy);
      finally
        vGraphics.Free;
      end;

      Result := True;
    finally
      FreeObj(vThmImage);
    end;

   {$ifdef bTrace}
    TraceEnd('  Ready');
   {$endif bTrace}
  end;


  procedure TView.DecodeImage(ADX, ADY :Integer);
  var
    vSize :TSize;
    vDelay :Integer;
    vStart :DWORD;
  begin
    vSize := FImgSize;
    if (ADX > 0) and (ADY > 0) and optUseWinSize then
      CorrectBoundEx(vSize, Size(ADX, ADY));

    SetAsyncTask(vSize);

    vDelay := IntIf(FThumbImage <> nil, DecodeWaitDelay, MaxInt);

    vStart := GetTickCount;
    while not CheckAsyncTask and (TickCountDiff(GetTickCount, vStart) < vDelay) do
      Sleep(1);
  end;


 {-----------------------------------------------------------------------------}

  procedure TView.SetAsyncTask(const ASize :TSize);
  begin
    InitThumbnailThread;
//  TraceF('SetAsyncTask %s...', [ExtractFileName(FSrcName)]);

    FAsyncTask := TTask.CreateEx(FSrcImage, FSrcName, FFrame, ASize);
(*  if FHasAlpha then
      FAsyncTask.FBackColor := FBkColor;  *)
    FAsyncTask.FOnTask := TaskEvent;
    FAsyncTask._AddRef;

    GThumbThread.AddTask(FAsyncTask);
  end;


  function TView.CheckAsyncTask :Boolean;
  begin
    Result := False;
    if FAsyncTask <> nil then begin
      if GThumbThread.CheckTask(FAsyncTask) then begin

        if FAsyncTask.FThumb <> nil then begin
          FreeObj(FThumbImage);
          FThumbImage := FAsyncTask.FThumb;
        end;

        FThumbSize   := FAsyncTask.FSize;
        FErrorMess   := FAsyncTask.FError;
        FIsThumbnail := False;

        FAsyncTask.FThumb := nil;
        FAsyncTask._Release;
        FAsyncTask := nil;
        Result := True;
      end;
    end;
  end;


  procedure TView.CancelTask;
  begin
    Assert(ValidInstance);
    if FAsyncTask <> nil then begin
//    TraceF('CancelTask %s...', [FSrcName]);
      GThumbThread.CancelTask(FAsyncTask);
      FAsyncTask._Release;
      FAsyncTask := nil;
    end;
  end;


  procedure TView.TaskEvent(ASender :Tobject);
  begin
//  TraceF('TaskEvent %d...', [Byte(FAsyncTask.FState)]);
  end;


 {-----------------------------------------------------------------------------}

  function GetUniqName(const aName, aExt :TString) :TString;
  var
    I :Integer;
  begin
    I := 0;
    Result := ChangeFileExtension(aName, aExt);
    while WinFileExists(Result) do begin
      Inc(I);
      Result := ChangeFileExtension(aName, aExt + Int2Str(I));
    end;
  end;


  function SetFileTimeName(const aName :TString; aAge :Integer {const aTime :TFileTime}) :Boolean;
  var
    vHandle :THandle;
  begin
    Result := False;
    vHandle := FileOpen(aName, fmOpenWrite);
//  vHandle := CreateFile(PTChar(aName), FILE_WRITE_ATTRIBUTES,  0, nil, OPEN_EXISTING, FILE_ATTRIBUTE_NORMAL, 0);
    if vHandle = INVALID_HANDLE_VALUE then
      Exit;
//  Result := SetFileTime(vHandle, nil, nil, @aTime);
    Result := FileSetDate(vHandle, aAge);
    FileClose(vHandle);
  end;



  function TView.SaveAs({const} ANewName, AFmtName :TString; aOrient, aQuality :Integer; aOptions :TSaveOptions) :Boolean;
  type
    EncoderParameters3 = packed record
      Count     :UINT;
      Parameter :array[0..2] of TEncoderParameter;
    end;
  const
    cTransform :array[0..8] of EncoderValue =
    (
      EncoderValue(0),
      EncoderValue(0),
      EncoderValueTransformFlipHorizontal,
      EncoderValueTransformRotate180,
      EncoderValueTransformFlipVertical,
      EncoderValueTransformRotate270,  {!!!}
      EncoderValueTransformRotate90,
      EncoderValueTransformRotate90, {!!!}
      EncoderValueTransformRotate270
    );
  var
    vMimeType, vNewName, vBakName :TString;
    vEncoderID :TGUID;
    vImage :TGPImage;
    vTransf :TEncoderValue;
    vParams :EncoderParameters3;
    vPParams :PEncoderParameters;
    vOrient :Integer;
    vSrcDate :Integer;
  begin
    Result := False;

    if AFmtName = '' then
      AFmtName := FFmtName
    else
    if ANewName = '' then
      ANewName := ChangeFileExtension(FSrcName, AFmtName);
    if ANewName = '' then
      ANewName := FSrcName;

    vNewName := '';
    try
      if not WinFileExists(FSrcName) then
        AppErrorFmt(strFileNotFound, [FSrcName]);

      vMimeType := 'image/' + StrLoCase(AFmtName);
      if GetEncoderClsid(vMimeType, vEncoderID) = -1 then
        AppErrorFmt(strNoEncoderFor, [AFmtName]);

      EnterCriticalSection(GDIPlusCS);
      try
        if FFrames = 1 then
          ReleaseSrcImage;

        vImage := TGPImage.Create(FSrcName);
        try
//        GDICheck(vImage.GetLastStatus);
          if vImage.GetLastStatus <> OK then
            AppError(strReadImageError);

          if GetFrameCount(vImage, nil, nil, nil) > 1 then
            AppError(strCantSaveFrames);

          vOrient := 0;
          if not GetTagValueAsInt(vImage, PropertyTagOrientation, vOrient) or (vOrient < 1) or (vOrient > 8) then
            vOrient := 0;

          vParams.Count := 0;

          if aQuality <> 0 then begin
            with vParams.Parameter[vParams.Count] do begin
              Guid := EncoderQuality;
              Type_ := EncoderParameterValueTypeLong;
              NumberOfValues := 1;
              Value := @aQuality;
            end;
            Inc(vParams.Count);
          end;

          if (soExifRotation in aOptions) and (StrEqual(AFmtName, 'jpeg') or StrEqual(AFmtName, 'tiff')) then begin

            { ������� ����� ��������� EXIF ��������� - loseless }
            if aOrient <> vOrient then
              SetTagValueInt(vImage, PropertyTagOrientation, aOrient);

          end else
          if (soTransformation in aOptions) then begin

            if StrEqual(AFmtName, 'jpeg') then begin
              { ������ ����� ������������� - ����� ��������� � �������... }

              vTransf := cTransform[aOrient];
              if vTransf <> EncoderValue(0) then begin
                if (((vImage.GetWidth mod 16) <> 0) or ((vImage.GetHeight mod 16) <> 0)) and not (soEnableLossy in aOptions) then
                  AppError(strLossyRotation);

                with vParams.Parameter[vParams.Count] do begin
                  Guid := EncoderTransformation;
                  Type_ := EncoderParameterValueTypeLong;
                  NumberOfValues := 1;
                  Value := @vTransf;
                end;
                Inc(vParams.Count);
              end;

            end else
            begin
              RotateImage(vImage, aOrient);
              GDICheck(vImage.GetLastStatus);
            end;

            if (vOrient <> 0) and (vOrient <> 1) then
              SetTagValueInt(vImage, PropertyTagOrientation, 1);
          end else
            Exit;

         {$ifdef bTrace}
          TraceBeg('Save...');
         {$endif bTrace}

          vNewName := GetUniqName(ANewName, '$$$');

          vPParams := nil;
          if vParams.Count > 0 then
            vPParams := Pointer(@vParams);
          vImage.Save(vNewName, vEncoderID, vPParams);
          GDICheck(vImage.GetLastStatus);

         {$ifdef bTrace}
          TraceEnd('  Ready');
         {$endif bTrace}

        finally
          FreeObj(vImage);
        end;

        vSrcDate := 0;
        if optKeepDateOnSave {soKeepDate in aOptions} then
          vSrcDate := FileAge(FSrcName);

        vBakName := GetUniqName(ANewName, '~' + ExtractFileExtension(ANewName) );
        if WinFileExists(ANewName) then
          ApiCheck(RenameFile(ANewName, vBakName));

        ApiCheck(RenameFile(vNewName, ANewName));

        if vSrcDate <> 0 then
          SetFileTimeName(ANewName, vSrcDate);

        DeleteFile(vBakName);

        Result := True;

      finally
        LeaveCriticalSection(GDIPlusCS);
      end;

    except
      on E :Exception do begin
        if (vNewName <> '') and WinFileExists(vNewName) then
          DeleteFile(vNewName);
        Raise;
      end;
    end;
  end;


 {-----------------------------------------------------------------------------}

  function TView.TagInfo(aCode :Integer; var aType :Integer; var aValue :Pointer) :Boolean;

    procedure LocStrTag(AID :ULONG);
    begin
      Result := GetTagValueAsStr(FSrcImage, AID, FStrTag);
      if Result then begin
        aValue := PTChar(FStrTag);
        aType := PVD_TagType_Str;
      end;
    end;

    procedure LocInt64Tag(AID :ULONG);
    begin
      Result := GetTagValueAsInt64(FSrcImage, AID, FInt64Tag);
      if Result then begin
        aValue := @FInt64Tag;
        aType := PVD_TagType_Int64;
      end;
    end;

    procedure LocIntTag(AID :ULONG);
    var
      vIntTag :Integer;
    begin
      Result := GetTagValueAsInt(FSrcImage, AID, vIntTag);
      if Result then begin
        aValue := Pointer(TIntPtr(vIntTag));
        aType := PVD_TagType_Int;
      end;
    end;

  begin
    Result := False;
    if FSrcImage = nil then begin
      {!!!}
      Exit;
    end;

    case aCode of
      PVD_Tag_Description  : LocStrTag(PropertyTagImageDescription);
      PVD_Tag_Time         : LocStrTag(PropertyTagExifDTOrig);  //PropertyTagDateTime
      PVD_Tag_EquipMake    : LocStrTag(PropertyTagEquipMake);
      PVD_Tag_EquipModel   : LocStrTag(PropertyTagEquipModel);
      PVD_Tag_Software     : LocStrTag(PropertyTagSoftwareUsed);
      PVD_Tag_Author       : LocStrTag(PropertyTagArtist);
      PVD_Tag_Copyright    : LocStrTag(PropertyTagCopyright);

      PVD_Tag_ExposureTime : LocInt64Tag(PropertyTagExifExposureTime);
      PVD_Tag_FNumber      : LocInt64Tag(PropertyTagExifFNumber);
      PVD_Tag_FocalLength  : LocInt64Tag(PropertyTagExifFocalLength);
      PVD_Tag_ISO          : LocIntTag(PropertyTagExifISOSpeed);
      PVD_Tag_Flash        : LocIntTag(PropertyTagExifFlash);
    end;
  end;


 {-----------------------------------------------------------------------------}

  function TView.Idle(ACX, ACY :Integer) :Boolean;
  begin
    Result := False;
    if FFirstShow = 0 then
      FFirstShow := GetTickCount;

    if CheckAsyncTask then begin
      Result := True;
      Exit;
    end;

    ACX := IntMin(ACX, FImgSize.CX);
    ACY := IntMin(ACY, FImgSize.CY);
    if not FIsThumbnail and ((ACX > FThumbSize.CX) or (ACY > FThumbSize.CY)) then begin
      if (FResizeStart = 0) or (FResizeSize.CX <> ACX) or (FResizeSize.CY <> ACY) then begin
        FResizeStart := GetTickCount;
        FResizeSize := Size(ACX, ACY);
      end;
    end;


    if (FResizeStart <> 0) and (FAsyncTask = nil) and (TickCountDiff(GetTickCount, FResizeStart) > StretchDelay) then begin
      FResizeStart := 0;
      if (ACX > FThumbSize.CX) or (ACY > FThumbSize.CY) then
        SetAsyncTask( Size(ACX, ACY) );
    end;

    if FIsThumbnail and (FAsyncTask = nil) and (TickCountDiff(GetTickCount, FFirstShow) > ThumbDelay) and not ScrollKeyPressed then
      { ���� � ��������� ������ ������������ ����� (� �� ������������ ������� ��������), �� ��������� ������� �� �������������, ���� ��� ��� }
      SetAsyncTask( Size(ACX, ACY) );
  end;


 {-----------------------------------------------------------------------------}
 {                                                                             }
 {-----------------------------------------------------------------------------}

  function CreateView(const AName :TString) :TView;
  var
    vImage :TGPImageEx;
  begin
    Result := nil;

//  TraceF('TGPImageEx.Create: %s...', [AName]);
    vImage := TGPImageEx.Create(AName);
//  TraceF('  Done. Status=%d', [Byte(vImage.GetLastStatus)]);

    if vImage.GetLastStatus = Ok then begin
      Result := TView.Create;
//    TraceF('%p TView.Create: %s', [Pointer(Result), AName]);
      Result.SetSrcImage(vImage);
      Result.FSrcName := AName;
    end else
      FreeObj(vImage);
  end;


 {-----------------------------------------------------------------------------}
 { TReviewGDIDecoder                                                           }
 {-----------------------------------------------------------------------------}

  constructor TReviewGDIDecoder.Create; {override;}
  begin
    inherited Create;
    FInitState := 1;
    FName := cDefGDIDecoderName;
    FTitle := cDefGDIDecoderTitle;
    FPriority := MaxInt;
    ResetSettings;
  end;


  destructor TReviewGDIDecoder.Destroy; {override;}
  begin
    DoneThumbnailThread;
    inherited Destroy;
  end;


  function TReviewGDIDecoder.NeedPrecache :boolean; {override;}
  begin
    Result := False;
  end;


  procedure TReviewGDIDecoder.ResetSettings; {override;}
  begin
    SetExtensions(cGDIPlusFormats, '');
  end;


  function TReviewGDIDecoder.GetState :TDecoderState; {override;}
  begin
    Result := rdsInternal;
  end;


  function TReviewGDIDecoder.CanWork(aLoad :Boolean) :Boolean; {virtual;}
  begin
    Result := True;
  end;


 {-----------------------------------------------------------------------------}

  function TReviewGDIDecoder.pvdFileOpen(AImage :TReviewImageRec) :Boolean; {override;}
  var
    vView :TView;
  begin
    Result := False;

    vView := CreateView(AImage.FName);

    if vView <> nil then begin
      AImage.FFormat := vView.FFmtName;
      AImage.FPages := vView.FFrames;
      AImage.FAnimated := (vView.FFrames > 1) and (vView.FDelays <> nil);
      AImage.FOrient := vView.FOrient0;

      AImage.FContext := vView;
      vView._AddRef;

      Result := True;
    end;
  end;


  function TReviewGDIDecoder.pvdGetPageInfo(AImage :TReviewImageRec) :Boolean; {override;}
  begin
    with TView(AImage.FContext) do begin
      SetFrame(AImage.FPage);

      AImage.FWidth  := FImgSize.cx;
      AImage.FHeight := FImgSize.cy;
      AImage.FBPP    := FPixels;

      if FFrames > 1 then begin
        if (FDelays <> nil) and (FFrame < FDelCount) then
          AImage.FDelay := PDelays(FDelays.Value)[FFrame] * 10;
//      if AImage.FDelay = 0 then
//        AImage.FDelay := cAnimationStep;  ������� � ReviewClasses
      end;

      Result := True;
    end;
  end;


  function TReviewGDIDecoder.pvdPageDecode(AImage :TReviewImageRec; ABkColor :Integer; AWidth, AHeight :Integer; ACache :Boolean) :Boolean; {override;}
  var
    vFastScroll :Boolean;
  begin
    with TView(AImage.FContext) do begin
      vFastScroll := not ACache and (TickCountDiff(GetTickCount, FLastDecode) < FastListDelay);

      FBkColor  := ABkColor;

      if optUseThumbnail = not (GetKeyState(VK_Shift) < 0) then
        InitThumbnail(0, 0 {cThumbSize, cThumbSize} );

      if not vFastScroll or (FThumbImage = nil) then
        DecodeImage(AWidth, AHeight);

      AImage.FWidth := FImgSize.cx;
      AImage.FHeight := FImgSize.cy;
      AImage.FBPP := FPixels;
      AImage.FSelfdraw := False;
      AImage.FTransparent := FHasAlpha;
//    AImage.FOrient := FOrient0;
(*
      if FFrames = 1 then
        { ����������� ����. ��� ������������� ���������� ������������� �� ��������� ������. }
        ReleaseSrcImage;
*)
      FFirstShow  := 0;
      if not ACache then
        FLastDecode := GetTickCount;
      Result := FThumbImage <> nil;
    end;
  end;


  procedure TReviewGDIDecoder.pvdPageFree(AImage :TReviewImageRec); {override;}
  begin
  end;


  procedure TReviewGDIDecoder.pvdFileClose(AImage :TReviewImageRec); {override;}
  begin
    if AImage.FContext <> nil then
      TView(AImage.FContext)._Release;
  end;


 {-----------------------------------------------------------------------------}

  function TReviewGDIDecoder.pvdTagInfo(AImage :TReviewImageRec; aCode :Integer; var aType :Integer; var aValue :Pointer) :Boolean; {override;}
  begin
    with TView(AImage.FContext) do begin
      aType := 0; aValue := nil;
      Result := TagInfo(aCode, aType, aValue);
    end;
  end;


 {-----------------------------------------------------------------------------}

(*
  function TReviewGDIDecoder.GetBitmapDC(AImage :TReviewImageRec; var ACX, ACY :Integer) :HDC; {virtual;}
  begin
    with TView(AImage.FContext) do begin
      CheckAsyncTask;
      Result := 0;
      if FThumbImage <> nil then begin
        ACX := FThumbImage.Width;
        ACY := FThumbImage.Height;
        Result := FThumbImage.DC;
      end;
    end;
  end;
*)


  function TReviewGDIDecoder.GetBitmapHandle(AImage :TReviewImageRec; var aIsThumbnail :Boolean) :HBitmap; {override;}
  begin
    with TView(AImage.FContext) do begin
      CheckAsyncTask;
      Result := 0;
      if FThumbImage <> nil then
        Result := FThumbImage.ReleaseBitmap;
      aIsThumbnail := FIsThumbnail;
    end;
  end;


  function TReviewGDIDecoder.Idle(AImage :TReviewImageRec; ACX, ACY :Integer) :Boolean; {override;}
  begin
    Result := TView(AImage.FContext).Idle(ACX, ACY);
  end;


  function TReviewGDIDecoder.Save(AImage :TReviewImageRec; const ANewName, AFmtName :TString; aOrient, aQuality :Integer; aOptions :TSaveOptions) :Boolean; {override;}
  begin
    if aOrient = 0 then
      aOrient := AImage.FOrient;
    Result := TView(AImage.FContext).SaveAs(ANewName, AFmtName, aOrient, aQuality, aOptions);
  end;



initialization
  InitializeCriticalSection(GDIPlusCS);

finalization
  DeleteCriticalSection(GDIPlusCS);
end.

