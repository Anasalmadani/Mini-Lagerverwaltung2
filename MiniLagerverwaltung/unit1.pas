unit Unit1;

{$mode objfpc}{$H+}

interface

uses
  Classes, SysUtils, Forms, Controls, Graphics, Dialogs,
  StdCtrls, Grids, ExtCtrls, LR_PGrid, IBConnection, SQLDB,
  uArtikel, uLagerService;

type

  { TFormMain
    Hauptformular der Lagerverwaltung.
    Aufgabe: Eingaben lesen, den Service aufrufen, Meldungen und
    Tabellen anzeigen. Fachregeln und Datenbankzugriff liegen
    ausschließlich in TLagerService. }
  TFormMain = class(TForm)
    { --- Buttons für die Artikelverwaltung --- }
    ButtonHinzufuegen: TButton;
    ButtonBearbeiten: TButton;
    ButtonLoeschen: TButton;

    { --- Buttons für die Lagerbewegungen --- }
    ButtonWareneingang: TButton;
    ButtonWarenausgang: TButton;
    ButtonStorno: TButton;

    { --- Eingabefelder für Artikeldaten --- }
    EditArtikelnummer: TEdit;
    EditBezeichnung: TEdit;
    EditEinzelpreis: TEdit;
    EditMindestbestand: TEdit;

    { --- Datenbankkomponenten (werden an den Service übergeben) --- }
    IBConnection1: TIBConnection;
    SQLTransaction1: TSQLTransaction;
    SQLQuery1: TSQLQuery;  { wird nicht mehr benutzt, kann im Formular gelöscht werden }

    LabelTitel: TLabel;
    StringGrid1: TStringGrid;  { Artikelliste }
    StringGrid2: TStringGrid;  { Bewegungsliste }

    { Ereignisse der Artikelverwaltung }
    procedure ButtonHinzufuegenClick(Sender: TObject);
    procedure ButtonBearbeitenClick(Sender: TObject);
    procedure ButtonLoeschenClick(Sender: TObject);

    { Ereignisse der Lagerbewegungen }
    procedure ButtonWareneingangClick(Sender: TObject);
    procedure ButtonWarenausgangClick(Sender: TObject);
    procedure ButtonStornoClick(Sender: TObject);
    procedure Panel1Click(Sender: TObject);
    procedure StringGrid1PrepareCanvas(Sender: TObject; aCol, aRow: Integer;
      aState: TGridDrawState);

  private
    FLagerService: TLagerService;  { Fachlogik und Datenbankzugriff }
    FBearbeiteNummer: string;      { leer = es wird gerade nichts bearbeitet }

    { Oberfläche einrichten }
    procedure TexteSetzen;
    procedure EreignisseZuweisen;
    procedure GridEinrichten;

    { Anzeige aktualisieren }
    procedure TabelleAktualisieren;
    procedure BewegungenAktualisieren;

    { Eingabefelder }
    procedure EingabenLeeren;
    function EingabenLesen(
      out Preis: Double;
      out Mindestbestand: Integer
    ): Boolean;

    { Bearbeitungsmodus }
    procedure BearbeitenBeenden;

    { Gemeinsame Logik für Wareneingang und Warenausgang }
    procedure BuchungAusfuehren(AZugang: Boolean);

  public
    constructor Create(TheOwner: TComponent); override;
    destructor Destroy; override;
  end;

var
  FormMain: TFormMain;

implementation

{$R *.lfm}

{ ===================== Aufbau und Abbau ===================== }

constructor TFormMain.Create(TheOwner: TComponent);
begin
  inherited Create(TheOwner);

  FBearbeiteNummer := '';

  { Service erzeugen. Der Konstruktor öffnet die Datenbankverbindung
    und lädt die vorhandenen Artikel. Bei einem Fehler (z. B.
    Datenbank nicht erreichbar) wird das Programm beendet. }
  try
    FLagerService := TLagerService.Create(IBConnection1, SQLTransaction1);
  except
    on E: Exception do
    begin
      ShowMessage('Datenbankfehler: ' + E.Message);
      FLagerService := nil;
      Application.Terminate;
      Exit;
    end;
  end;

  TexteSetzen;
  EreignisseZuweisen;
  GridEinrichten;

  { Beim Start beide Tabellen mit den Daten aus der Datenbank füllen }
  TabelleAktualisieren;
  BewegungenAktualisieren;
end;

destructor TFormMain.Destroy;
begin
  { Der Service gibt seine Artikelobjekte selbst frei.
    Verbindung und Transaktion gehören dem Formular. }
  FreeAndNil(FLagerService);
  inherited Destroy;
end;

{ ===================== Oberfläche einrichten ===================== }

procedure TFormMain.TexteSetzen;
begin
  LabelTitel.Caption := 'Mini-Lagerverwaltung';

  ButtonHinzufuegen.Caption := 'Hinzufügen';
  ButtonBearbeiten.Caption := 'Bearbeiten';
  ButtonLoeschen.Caption := 'Löschen';

  ButtonWareneingang.Caption := 'Wareneingang';
  ButtonWarenausgang.Caption := 'Warenausgang';
  ButtonStorno.Caption := 'Bewegung stornieren';
end;

procedure TFormMain.EreignisseZuweisen;
begin
  ButtonHinzufuegen.OnClick := @ButtonHinzufuegenClick;
  ButtonBearbeiten.OnClick := @ButtonBearbeitenClick;
  ButtonLoeschen.OnClick := @ButtonLoeschenClick;

  ButtonWareneingang.OnClick := @ButtonWareneingangClick;
  ButtonWarenausgang.OnClick := @ButtonWarenausgangClick;
  ButtonStorno.OnClick := @ButtonStornoClick;
end;

procedure TFormMain.GridEinrichten;
begin
  { Artikeltabelle.
    Reihenfolge : erst Spalten und feste Zeilen,
    danach die Zeilenanzahl (mindestens Kopfzeile + 1 Datenzeile). }
  StringGrid1.FixedCols := 0;
  StringGrid1.ColCount := 5;
  StringGrid1.FixedRows := 1;
  StringGrid1.RowCount := 2;

  StringGrid1.Cells[0, 0] := 'Artikelnummer';
  StringGrid1.Cells[1, 0] := 'Bezeichnung';
  StringGrid1.Cells[2, 0] := 'Einzelpreis';
  StringGrid1.Cells[3, 0] := 'Mindestbestand';
  StringGrid1.Cells[4, 0] := 'Bestand';

  { Bewegungstabelle (gleiche Reihenfolge der Einstellungen) }
  StringGrid2.FixedCols := 0;
  StringGrid2.ColCount := 6;
  StringGrid2.FixedRows := 1;
  StringGrid2.RowCount := 2;

  StringGrid2.Cells[0, 0] := 'ID';
  StringGrid2.Cells[1, 0] := 'Datum / Uhrzeit';
  StringGrid2.Cells[2, 0] := 'Artikelnummer';
  StringGrid2.Cells[3, 0] := 'Bewegungsart';
  StringGrid2.Cells[4, 0] := 'Menge';
  StringGrid2.Cells[5, 0] := 'Bemerkung';

    { Artikeltabelle: ganze Zeile wählbar, kein Tippen in Zellen }
  StringGrid1.Options := StringGrid1.Options + [goRowSelect] - [goEditing];
  StringGrid1.AlternateColor := RGBToColor(245, 245, 245);  { Zebra-Streifen }
  StringGrid1.ColWidths[0] := 110;   { Artikelnummer }
  StringGrid1.ColWidths[1] := 220;   { Bezeichnung }
  StringGrid1.ColWidths[2] := 90;    { Einzelpreis }
  StringGrid1.ColWidths[3] := 110;   { Mindestbestand }
  StringGrid1.ColWidths[4] := 80;    { Bestand }

  { Bewegungstabelle }
  StringGrid2.Options := StringGrid2.Options + [goRowSelect] - [goEditing];
  StringGrid2.AlternateColor := RGBToColor(245, 245, 245);
  StringGrid2.ColWidths[0] := 50;    { ID }
  StringGrid2.ColWidths[1] := 150;   { Datum / Uhrzeit }
  StringGrid2.ColWidths[2] := 110;   { Artikelnummer }
  StringGrid2.ColWidths[3] := 110;   { Bewegungsart }
  StringGrid2.ColWidths[4] := 60;    { Menge }
  StringGrid2.ColWidths[5] := 200;   { Bemerkung }



end;

{ ===================== Anzeige aktualisieren ===================== }

procedure TFormMain.TabelleAktualisieren;
var
  i, c: Integer;
  Artikel: TArtikel;
  Anzahl: Integer;
  NeueZeilenAnzahl: Integer;
begin
  Anzahl := FLagerService.ArtikelAnzahl;

  { Kopfzeile + Artikel, aber mindestens 2 Zeilen,
    weil das Grid eine feste Zeile und eine Datenzeile braucht }
  NeueZeilenAnzahl := Anzahl + 1;
  if NeueZeilenAnzahl < 2 then
    NeueZeilenAnzahl := 2;

  StringGrid1.BeginUpdate;
  try
    StringGrid1.RowCount := NeueZeilenAnzahl;

    { Alle Datenzellen leeren, damit nach dem Löschen
      keine alten Daten stehen bleiben }
    for i := 1 to StringGrid1.RowCount - 1 do
      for c := 0 to StringGrid1.ColCount - 1 do
        StringGrid1.Cells[c, i] := '';

    { Artikel aus dem Service in die Tabelle schreiben }
    for i := 0 to Anzahl - 1 do
    begin
      Artikel := FLagerService.ArtikelAnIndex(i);

      if Artikel <> nil then
      begin
        StringGrid1.Cells[0, i + 1] := Artikel.Artikelnummer;
        StringGrid1.Cells[1, i + 1] := Artikel.Bezeichnung;
        StringGrid1.Cells[2, i + 1] :=
          FormatFloat('0.00', Artikel.Einzelpreis);
        StringGrid1.Cells[3, i + 1] := IntToStr(Artikel.Mindestbestand);
        StringGrid1.Cells[4, i + 1] := IntToStr(Artikel.Bestand);
      end;
    end;
  finally
    StringGrid1.EndUpdate;
  end;
end;

procedure TFormMain.BewegungenAktualisieren;
var
  B: TBewegungArray;
  i, c, Zeilen: Integer;
begin
  { Alle Bewegungen aus der Datenbank lesen (neueste zuerst) }
  B := FLagerService.BewegungenLesen('');

  Zeilen := Length(B) + 1;
  if Zeilen < 2 then
    Zeilen := 2;

  StringGrid2.BeginUpdate;
  try
    StringGrid2.RowCount := Zeilen;

    { Alte Inhalte entfernen }
    for i := 1 to StringGrid2.RowCount - 1 do
      for c := 0 to StringGrid2.ColCount - 1 do
        StringGrid2.Cells[c, i] := '';

    { Bewegungen in die Tabelle schreiben }
    for i := 0 to High(B) do
    begin
      StringGrid2.Cells[0, i + 1] := IntToStr(B[i].ID);
      StringGrid2.Cells[1, i + 1] :=
        FormatDateTime('dd.mm.yyyy hh:nn:ss', B[i].Zeitpunkt);
      StringGrid2.Cells[2, i + 1] := B[i].Artikelnummer;

      if B[i].Art = ART_ZUGANG then
        StringGrid2.Cells[3, i + 1] := 'Wareneingang'
      else
        StringGrid2.Cells[3, i + 1] := 'Warenausgang';

      StringGrid2.Cells[4, i + 1] := IntToStr(B[i].Menge);
      StringGrid2.Cells[5, i + 1] := B[i].Bemerkung;
    end;
  finally
    StringGrid2.EndUpdate;
  end;
end;

{ ===================== Eingabefelder ===================== }

procedure TFormMain.EingabenLeeren;
begin
  EditArtikelnummer.Clear;
  EditBezeichnung.Clear;
  EditEinzelpreis.Clear;
  EditMindestbestand.Clear;
end;

function TFormMain.EingabenLesen(
  out Preis: Double;
  out Mindestbestand: Integer
): Boolean;
begin
  Result := False;
  Preis := 0;
  Mindestbestand := 0;

  { Preis prüfen }
  if not TryStrToFloat(Trim(EditEinzelpreis.Text), Preis) then
  begin
    ShowMessage('Bitte einen gültigen Preis eingeben.');
    EditEinzelpreis.SetFocus;
    Exit;
  end;

  { Mindestbestand prüfen }
  if not TryStrToInt(Trim(EditMindestbestand.Text), Mindestbestand) then
  begin
    ShowMessage('Bitte einen gültigen Mindestbestand eingeben.');
    EditMindestbestand.SetFocus;
    Exit;
  end;

  Result := True;
end;

{ ===================== Artikelverwaltung ===================== }

procedure TFormMain.ButtonHinzufuegenClick(Sender: TObject);
var
  Preis: Double;
  Mindestbestand: Integer;
  Fehlermeldung: string;
begin
  if not EingabenLesen(Preis, Mindestbestand) then
    Exit;

  { Die fachlichen Prüfungen (leere Felder, doppelte Nummer usw.)
    macht der Service und meldet Fehler über Fehlermeldung zurück }
  if FLagerService.ArtikelHinzufuegen(
    EditArtikelnummer.Text,
    EditBezeichnung.Text,
    Preis,
    Mindestbestand,
    Fehlermeldung
  ) then
  begin
    TabelleAktualisieren;
    EingabenLeeren;
    ShowMessage('Artikel wurde hinzugefügt.');
  end
  else
    ShowMessage(Fehlermeldung);
end;

procedure TFormMain.ButtonBearbeitenClick(Sender: TObject);
var
  Artikel: TArtikel;
  Preis: Double;
  Mindestbestand: Integer;
  Fehlermeldung: string;
  Nummer: string;
  i: Integer;
begin
  { ---- Schritt 2: Änderungen speichern ----
    Der Button heißt jetzt "Speichern" und FBearbeiteNummer ist gesetzt }
  if FBearbeiteNummer <> '' then
  begin
    if not EingabenLesen(Preis, Mindestbestand) then
      Exit;

    if FLagerService.ArtikelBearbeiten(
      FBearbeiteNummer,
      EditBezeichnung.Text,
      Preis,
      Mindestbestand,
      Fehlermeldung
    ) then
    begin
      BearbeitenBeenden;
      TabelleAktualisieren;
      ShowMessage('Artikel wurde bearbeitet.');
    end
    else
      ShowMessage(Fehlermeldung);

    Exit;
  end;

  { ---- Schritt 1: nach der Artikelnummer fragen ---- }
  Nummer := '';

  if not InputQuery(
    'Artikel bearbeiten',
    'Welche Artikelnummer soll bearbeitet werden?',
    Nummer
  ) then
    Exit;  { Benutzer hat "Abbrechen" gedrückt }

  Nummer := Trim(Nummer);

  if Nummer = '' then
  begin
    ShowMessage('Bitte eine Artikelnummer eingeben.');
    Exit;
  end;

  Artikel := FLagerService.ArtikelSuchen(Nummer);

  if Artikel = nil then
  begin
    ShowMessage('Ein Artikel mit dieser Nummer existiert nicht.');
    Exit;
  end;

  { Passende Zeile in der Tabelle markieren }
  for i := 1 to StringGrid1.RowCount - 1 do
    if SameText(StringGrid1.Cells[0, i], Artikel.Artikelnummer) then
    begin
      StringGrid1.Row := i;
      Break;
    end;

  { Aktuelle Werte in die Eingabefelder laden }
  EditArtikelnummer.Text := Artikel.Artikelnummer;
  EditArtikelnummer.Enabled := False;  { Nummer darf nicht geändert werden }
  EditBezeichnung.Text := Artikel.Bezeichnung;
  EditEinzelpreis.Text := FloatToStr(Artikel.Einzelpreis);
  EditMindestbestand.Text := IntToStr(Artikel.Mindestbestand);

  { In den Bearbeitungsmodus wechseln }
  FBearbeiteNummer := Artikel.Artikelnummer;
  ButtonBearbeiten.Caption := 'Speichern';
  EditBezeichnung.SetFocus;
end;

procedure TFormMain.BearbeitenBeenden;
begin
  { Zurück in den normalen Modus }
  FBearbeiteNummer := '';
  ButtonBearbeiten.Caption := 'Bearbeiten';
  EditArtikelnummer.Enabled := True;
  EingabenLeeren;
end;

procedure TFormMain.ButtonLoeschenClick(Sender: TObject);
var
  Nummer: string;
  Fehlermeldung: string;
begin
  Nummer := '';

  { Nach der Artikelnummer fragen }
  if not InputQuery(
    'Artikel löschen',
    'Welche Artikelnummer soll gelöscht werden?',
    Nummer
  ) then
    Exit;  { Benutzer hat "Abbrechen" gedrückt }

  Nummer := Trim(Nummer);

  if Nummer = '' then
  begin
    ShowMessage('Bitte eine Artikelnummer eingeben.');
    Exit;
  end;

  { Prüfen, ob es den Artikel gibt }
  if FLagerService.ArtikelSuchen(Nummer) = nil then
  begin
    ShowMessage('Ein Artikel mit dieser Nummer existiert nicht.');
    Exit;
  end;

  { Sicherheitsabfrage }
  if MessageDlg(
    'Soll der Artikel ' + Nummer + ' wirklich gelöscht werden?',
    mtConfirmation,
    [mbYes, mbNo],
    0
  ) <> mrYes then
    Exit;

  { Der Service lehnt das Löschen ab, wenn der Artikel Bewegungen hat }
  if FLagerService.ArtikelLoeschen(Nummer, Fehlermeldung) then
  begin
    TabelleAktualisieren;
    EingabenLeeren;
    ShowMessage('Artikel wurde gelöscht.');
  end
  else
    ShowMessage(Fehlermeldung);
end;

{ ===================== Lagerbewegungen ===================== }

procedure TFormMain.BuchungAusfuehren(AZugang: Boolean);
var
  Titel, Nummer, MengeText, Fehlermeldung: string;
  Menge: Integer;
  Artikel: TArtikel;
begin
  { Gemeinsame Logik: AZugang = True ist Wareneingang,
    False ist Warenausgang }
  if AZugang then
    Titel := 'Wareneingang'
  else
    Titel := 'Warenausgang';

  { Artikelnummer abfragen }
  Nummer := '';
  if not InputQuery(Titel, 'Artikelnummer:', Nummer) then
    Exit;

  Nummer := Trim(Nummer);
  Artikel := FLagerService.ArtikelSuchen(Nummer);

  if Artikel = nil then
  begin
    ShowMessage('Ein Artikel mit dieser Nummer existiert nicht.');
    Exit;
  end;

  { Menge abfragen und prüfen }
  MengeText := '';
  if not InputQuery(Titel, 'Menge:', MengeText) then
    Exit;

  if (not TryStrToInt(Trim(MengeText), Menge)) or (Menge <= 0) then
  begin
    ShowMessage('Bitte eine ganze Zahl größer als 0 eingeben.');
    Exit;
  end;

  { Buchen. Der Service verhindert negative Bestände. }
  if FLagerService.BewegungBuchen(Nummer, AZugang, Menge, Fehlermeldung) then
  begin
    TabelleAktualisieren;
    BewegungenAktualisieren;
    ShowMessage('Gebucht. Neuer Bestand: ' + IntToStr(Artikel.Bestand));
  end
  else
    ShowMessage(Fehlermeldung);
end;

procedure TFormMain.ButtonWareneingangClick(Sender: TObject);
begin
  BuchungAusfuehren(True);
end;

procedure TFormMain.ButtonWarenausgangClick(Sender: TObject);
begin
  BuchungAusfuehren(False);
end;

procedure TFormMain.ButtonStornoClick(Sender: TObject);
var
  IDText, Fehlermeldung: string;
  ID: Integer;
begin
  { ID der zu stornierenden Bewegung abfragen (steht in der Tabelle) }
  IDText := '';
  if not InputQuery(
    'Bewegung stornieren',
    'ID der Bewegung (siehe Tabelle):',
    IDText
  ) then
    Exit;

  if not TryStrToInt(Trim(IDText), ID) then
  begin
    ShowMessage('Bitte eine gültige ID eingeben.');
    Exit;
  end;

  { Sicherheitsabfrage. Bewegungen werden nie gelöscht,
    sondern durch eine Gegenbuchung ausgeglichen. }
  if MessageDlg(
    'Bewegung ' + IntToStr(ID) + ' wirklich stornieren? ' +
    'Es wird eine Gegenbuchung angelegt.',
    mtConfirmation,
    [mbYes, mbNo],
    0
  ) <> mrYes then
    Exit;

  if FLagerService.BewegungStornieren(ID, Fehlermeldung) then
  begin
    TabelleAktualisieren;
    BewegungenAktualisieren;
    ShowMessage('Bewegung wurde storniert.');
  end
  else
    ShowMessage(Fehlermeldung);
end;

procedure TFormMain.Panel1Click(Sender: TObject);
begin

end;



procedure TFormMain.StringGrid1PrepareCanvas(Sender: TObject;
  aCol, aRow: Integer; aState: TGridDrawState);
var
  Bestand, Minimum: Integer;
begin
  { Kopfzeile und markierte Zeile nicht einfärben }
  if (aRow < 1) or (gdSelected in aState) then
    Exit;

  { Zeile hellrot, wenn der Bestand unter dem Mindestbestand liegt }
  if TryStrToInt(StringGrid1.Cells[4, aRow], Bestand) and
     TryStrToInt(StringGrid1.Cells[3, aRow], Minimum) and
     (Bestand < Minimum) then
    StringGrid1.Canvas.Brush.Color := RGBToColor(255, 215, 215);
end;


end.
