program PrjHousePhotosRemote;

uses
  System.StartUpCopy,
  FMX.Forms,
  HousePhotosRemote in 'HousePhotosRemote.pas' {HousePhotosForm};

{$R *.res}

begin
  Application.Initialize;
  Application.CreateForm(THousePhotosForm, HousePhotosForm);
  Application.Run;
end.
