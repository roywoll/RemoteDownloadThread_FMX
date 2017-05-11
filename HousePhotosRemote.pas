unit HousePhotosRemote;
//
// Keeping your application responsive when loading remote bitmaps
//
// The cool thing about this demo is that a slow server that feeds
// the bitmap does not degrade the user performance in scrolling through the
// dataset
//
// The following details all the steps required.
//
// 1. A local table (Pictures) contains the file reference. The remote file
//    ends in .jpg and does not have spaces so the code adapts the filename
//    ccordingly. In the form's OnShow event, the program creates a TImageBlock
//    item for each record in the Pictures and sets its dirty property to true.
//    It also creates a TImageControl and TLabel within a TLayout for
//    each TImageBlock and places them in the TVertScrollBox (PictureContainer).
//    See the TemplatePictureItem that resides on the tiImage tab page.
//
// 2. The program starts a thread (from the form's OnShow event) to load the
//    visible pictures from the remote location (StartThreadLoadVisiblePictures).
//
//    This keeps the user experience smooth without jerky transitions.
//    This thread continually runs and loads bitmaps on the current page if
//    they have not been previously loaded (See method LoadVisiblePictures).
//
//    The thread does not load all the bitmaps as this could be too slow if
//    you have a lot of pictures). Once a bitmap is loaded, it sets the dirty
//    property to true so its not reloaded again (TImageBlock.Dirty).
//
//    Note: The program defines the method DownloadStream to load the remote
//    pictures. using Indy  (see method DownloadStream). Also note that TBitmap
//    loading needs to be done on the main thread, thus the call to Synchronize.
//
// 3. The message 'loading is displayed for the record' if the bitmap is still
//    loading (for instance, could be a slower server where the bitmaps are stored).
//
// 4. TemplatePictureItem is used as a template layout for each image and related
//    info.
//
// 5. When clicking on an image, it will open up another tab page with the image
//    fully expanded.
//
// 6. If you wish to see the performance without using a background thread then
//    click the combo at the top right and select "Without Thread"
//
interface

uses
  System.SysUtils, System.Types, System.UITypes, System.Classes, System.Variants,
  FMX.Types, FMX.Controls, FMX.Forms, FMX.Graphics, FMX.Dialogs, FMX.StdCtrls,
  FMX.ScrollBox,
  FMX.Controls.Presentation, FMX.Layouts,
  System.Rtti, System.Bindings.Outputs, Fmx.Bind.Editors, Data.Bind.EngExt,
  Fmx.Bind.DBEngExt, Data.Bind.Components, Data.Bind.DBScope,
  Data.DB,
  FireDAC.Comp.DataSet, FireDAC.Comp.Client,
  Generics.Collections, Generics.Defaults,
  FMX.Objects,
  FMX.TabControl, FireDAC.Stan.Intf, FireDAC.Stan.Option, FireDAC.Stan.Param,
  FireDAC.Stan.StorageBin, FireDAC.Stan.Error, FireDAC.DatS, FireDAC.Phys.Intf,
  FireDAC.DApt.Intf, FMX.Edit, FMX.wwEdit, FMX.wwComboEdit;

type
  TImageBlock = class
  public
    ID: Integer;
    Dirty: boolean;
    Image: TImageControl;
    Layout: TLayout;
    LoadingControl: TLabel;
    InfoControl: TLabel;
    Location: string;
  end;

  THousePhotosForm = class(TForm)
    TitleLayout: TLayout;
    Label1: TLabel;
    TitleLayoutRight: TLayout;
    SelectButton: TButton;
    TitleLayoutLeft: TLayout;
    BackButton: TButton;
    btnRefresh: TButton;
    tcMain: TTabControl;
    tiImages: TTabItem;
    BindSourceDB12: TBindSourceDB;
    PictureContainer: TVertScrollBox;
    icItem: TImageControl;
    TemplatePictureItem: TLayout;
    lblRoomName: TLabel;
    lblLoading: TLabel;
    tiImage: TTabItem;
    Pictures: TFDMemTable;
    cbLoadMethod: TwwComboEdit;
    procedure FormShow(Sender: TObject);
    procedure PictureContainerResize(Sender: TObject);
    procedure FormClose(Sender: TObject; var Action: TCloseAction);
    procedure btnRefreshClick(Sender: TObject);
    procedure BackButtonClick(Sender: TObject);
    procedure PictureItemClick(Sender: TObject);
    procedure cbLoadMethodClosePopup(Sender: TObject);
    procedure PictureContainerViewportPositionChange(Sender: TObject;
      const OldViewportPosition, NewViewportPosition: TPointF;
      const ContentSizeChanged: Boolean);
    procedure PictureItemTap(Sender: TObject; const Point: TPointF);
  private
    LoadPictureThread: TThread;
    procedure OpenDetail(imageBlock: TImageBlock);
    function IsLoadingInBackground: boolean;
    procedure LoadVisiblePictures;  // Actual thread to load remote bitmaps
    procedure StartThreadLoadVisiblePictures; // Starts monitoring bitmap loading
    procedure StopThreadLoadVisiblePictures; // End monitoring bitmap loading
  public
    DefaultWidth, DefaultHeight: Single;
  end;

var
  HousePhotosForm: THousePhotosForm;

implementation

uses idhttp,
  System.RegularExpressions, fmx.platform;

{$R *.fmx}
const RemoteServer = 'http://ec2-54-215-239-17.us-west-1.compute.amazonaws.com/downloads/Photos/Home/';
   PicturesPerRow = 2;
   RowsInContainer = 2;

var
  ImageBlockList: TObjectList<TImageBlock>;

function wwHasTouchTracking: Boolean;
var SystemInfo: IFMXSystemInformationService;
begin
  TPlatformServices.Current.SupportsPlatformService
    (IFMXSystemInformationService, IInterface(SystemInfo));
  Result := Assigned(SystemInfo) and
    (TScrollingBehaviour.TouchTracking
    in SystemInfo.GetScrollingBehaviour);
end;

{$REGION 'TFetchDataThread'}
type
  TExecuteMethod = procedure of object;
  TFetchDataThread = class(TThread)
  private
    FExecuteMethod: TExecuteMethod;
  protected
    procedure Execute; override;
    constructor Create(AExecuteMethod: TExecuteMethod);
  end;

constructor TFetchDataThread.Create(AExecuteMethod: TExecuteMethod);
begin
  inherited Create(false);
  FExecuteMethod := AExecuteMethod;
end;

procedure TFetchDataThread.Execute;
begin
  try
    FExecuteMethod;
  except
  end;
end;
{$endregion}


// Download bitmap from remote server
function DownloadStream(uri: String; var mStream: TMemoryStream): Boolean;
var http: TIdHttp;
begin
  Result := true;
  http:= TIdHTTP.Create(nil);
  try
    try
      http.Get(uri, mstream);
      mstream.Position:= 0;
    except
      result:=false;
    end;
  finally
    http.Free;
  end;
end;

{$region 'Background Thread to Load Pictures'}

procedure THousePhotosForm.StopThreadLoadVisiblePictures;
begin
  if not IsLoadingInBackground then exit;

  LoadPictureThread.Terminate;
  LoadPictureThread.waitfor;
end;

procedure THousePhotosForm.PictureItemTap(Sender: TObject;
  const Point: TPointF);
begin
  OpenDetail(ImageBlockList[TLayout(Sender).Tag]);
end;

procedure THousePhotosForm.StartThreadLoadVisiblePictures;
begin
  LoadPictureThread:= TFetchDataThread.Create(LoadVisiblePictures);
end;

procedure THousePhotosForm.FormClose(Sender: TObject; var Action: TCloseAction);
begin
  StopThreadLoadVisiblePictures;
end;

procedure THousePhotosForm.OpenDetail(imageBlock: TImageBlock);
begin
   if imageBlock.Dirty then exit; // Don't load detail yet

   icItem.Bitmap.Assign(imageBlock.Image.Bitmap);
   lblRoomName.Text:= imageblock.Location;
   tcMain.SetActiveTabWithTransition(tiImage, TTabTransition.Slide,
      TTabTransitionDirection.Normal);
   BackButton.Visible:= true;
end;

procedure THousePhotosForm.PictureItemClick(Sender: TObject);
begin
  OpenDetail(ImageBlockList[TLayout(Sender).Tag]);
end;

procedure THousePhotosForm.LoadVisiblePictures;
// Loads images from remote server in the background
  function RefreshCurrentPage: boolean;
  var row: integer;
      dirty: boolean;
      pictureLocation, filename: string;
      multiCount: integer;
      TopRow: integer;
      TopRecNo: integer;
      stream: TMemoryStream;

      function HaveNewTop: boolean;
      var NewTopRow, NewTopRecNo: integer;
      begin
        NewTopRow:= trunc(PictureContainer.ViewportPosition.Y/DefaultHeight);
        NewTopRecNo:= NewTopRow * PicturesPerRow;
        result:= NewTopRecNo<>TopRecNo;
      end;
  begin
    result:= false;
    multiCount:= round(PicturesPerRow * (PictureContainer.Height/DefaultHeight)) + PicturesPerRow;
    TopRow:= trunc(PictureContainer.ViewportPosition.Y/DefaultHeight);
    TopRecNo:= TopRow * PicturesPerRow;

    for row := TopRecNo to TopRecNo + multiCount-1 + PicturesPerRow do
    begin
      if row>=ImageBlockList.count then continue;
      if row<0 then continue;
      dirty:= ImageBlockList[row].Dirty;

      PictureLocation:= ImageBlockList[row].Location;
      fileName:= RemoteServer + PictureLocation + '.jpg';
      fileName:= filename.Replace(' ', '');
      if not dirty then
        continue;
      result:= true;

      if (row>=TopRecNo) and
         (row<TopRecNo + multiCount) then
         result:= true;

      stream:= TMemoryStream.Create;
      if not DownloadStream(filename, stream) then
      begin
         TThread.Synchronize(TThread.CurrentThread,
           procedure
           begin
             ImageBlockList[row].LoadingControl.Text:= 'Unable to Load Image';
           end);
      end
      else begin
        TThread.Synchronize(TThread.CurrentThread,
          procedure
          begin
            ImageBlockList[row].Image.Bitmap.LoadFromStream(stream);
            ImageBlockList[row].LoadingControl.Visible:= false;
            ImageBlockList[row].dirty:= false;
            if (row>=TopRecNo) and
             (row<TopRecNo + multiCount) then
              PictureContainer.Repaint;
          end);
      end;
      stream.Free;
      if IsLoadingInBackground and
         LoadPictureThread.CheckTerminated then exit;

      sleep(50);  // Increase delay if background loading is still too intensive
                  // for good user experience in scrolling
      if HaveNewTop then
        break;
    end;

  end;
begin
  while true do
  begin
    RefreshCurrentPage;
    if (LoadPictureThread<>nil) then
    begin
       if LoadPictureThread.CheckTerminated then exit;
    end
    else
      break;  // Not running in thread so just break

    sleep(50);
  end;

end;

procedure THousePhotosForm.cbLoadMethodClosePopup(Sender: TObject);
begin
  if cbLoadMethod.Text = 'Use Thread' then
  begin
    StartThreadLoadVisiblePictures;
  end
  else begin
    StopThreadLoadVisiblePictures;
    LoadPictureThread:= nil;
    LoadVisiblePictures;
  end;
  btnRefresh.OnClick(self);

end;

{$endregion}

procedure THousePhotosForm.PictureContainerResize(Sender: TObject);
var curRecNo: integer;
   imageBlockData: TImageBlock;
begin
  DefaultWidth:= PictureContainer.Width/PicturesPerRow;
  DefaultHeight:= PictureContainer.Height/RowsInContainer;
  PictureContainer.BeginUpdate;
  try
    for curRecNo := 0 to ImageBlockList.Count-1 do
    begin
      imageBlockData:= ImageBlockList[curRecNo];
      imageBlockData.Layout.Width := DefaultWidth - 1;
      imageBlockData.Layout.Height := DefaultHeight - 1;
      imageBlockData.Layout.Position.X := (curRecNo mod PicturesPerRow) *
        DefaultWidth;
      imageBlockData.Layout.Position.Y := (curRecNo div PicturesPerRow) *
        DefaultHeight;
    end;
  finally
    PictureContainer.EndUpdate;
  end;

end;

// If loading without thread, then we need to get remote bitmaps after scroll
procedure THousePhotosForm.PictureContainerViewportPositionChange(
  Sender: TObject; const OldViewportPosition, NewViewportPosition: TPointF;
  const ContentSizeChanged: Boolean);
begin
  if IsLoadingInBackground then exit;
  LoadVisiblePictures;
end;

// Perform initialization and creation of items/images in PictureContainer
procedure THousePhotosForm.FormShow(Sender: TObject);
var
  imageBlockData: TImageBlock;
  curRecNo: Integer;
  component: TComponent;
begin
  // Create list of images in a TVertScrollBox - We'll load images in the background
  // Use TemplatePictureItem as template for each item
  curRecNo := 0;
  PictureContainer.BeginUpdate;
  try
    while not Pictures.eof do
    begin
      imageBlockData := TImageBlock.Create; // (self);

      imageBlockData.ID := Pictures.FieldByName('ID').AsInteger;
      imageBlockData.Location := Pictures.FieldByName('Location').AsString;
      imageBlockData.Dirty := True;
      imageBlockData.Location := Pictures.FieldByName('Location').Text;

      imageBlockData.Layout:= TemplatePictureItem.Clone(self) as TLayout;
      imageBlockData.Layout.Tag:= curRecNo; // For when click on item
      imageBlockData.Layout.Parent:= PictureContainer;

      imageBlockData.Layout.Width := DefaultWidth - 1;
      imageBlockData.Layout.Height := DefaultHeight - 1;
      imageBlockData.Layout.Position.X := (curRecNo mod PicturesPerRow) *
        DefaultWidth;
      imageBlockData.Layout.Position.Y := (curRecNo div PicturesPerRow) *
        DefaultHeight;
      if wwHasTouchTracking then
        imageBlockData.Layout.OnTap:= PictureItemTap
      else
        imageBlockData.Layout.OnClick:= PictureItemClick;
      for component in imageBlockData.Layout do
      begin
         if (component is TLabel) and (TLabel(component).Text = 'lblRoomName') then
           imageBlockData.InfoControl:= TLabel(component)
         else if (component is TImageControl) then
           imageBlockData.Image:= TImageControl(component)
         else if (component is TLabel) and (TLabel(component).Text = 'Loading...') then
               imageBlockData.LoadingControl:= TLabel(component)
      end;
      imageBlockData.InfoControl.Text := imageBlockData.Location;
      imageBlockData.LoadingControl.Position.Y := (DefaultHeight - 20) / 2;

      ImageBlockList.Add(imageBlockData);

      inc(curRecNo);
      Pictures.Next;
    end;
  finally
    PictureContainer.EndUpdate;
  end;

  BackButton.Visible:= false;
  lblLoading.Visible:= false;
  TemplatePictureItem.Align:= TAlignLayout.Client;
  StartThreadLoadVisiblePictures;

end;

// Refetch from server
procedure THousePhotosForm.BackButtonClick(Sender: TObject);
begin
  if tcMain.ActiveTab <> tiImages then
  begin
    tcMain.SetActiveTabWithTransition(tiImages, TTabTransition.Slide,
      TTabTransitionDirection.Reversed);
    BackButton.Visible:= false;
  end
end;

// Clears all the bitmaps so that they must be redownloaded
procedure THousePhotosForm.btnRefreshClick(Sender: TObject);
var imageBlock : TImageBlock;
begin
  for imageBlock in ImageBlockList do
  begin
    imageBlock.Image.Bitmap.Clear(TAlphaColorRec.White);
    imageBlock.dirty:= true;
    ImageBlock.LoadingControl.Visible:= true;
  end;
  Invalidate;

  if not IsLoadingInBackground then // Not loading bitmaps in a thread
     LoadVisiblePictures;
end;

function THousePhotosForm.IsLoadingInBackground: boolean;
begin
  result:= (LoadPictureThread <> nil);
end;

initialization
   // ImageBlockList stores bitmaps after they are loaded
   // Background tasks update ImageBlockList
   ImageBlockList := TObjectList<TImageBlock>.Create;
finalization
   ImageBlockList.Free;
end.
