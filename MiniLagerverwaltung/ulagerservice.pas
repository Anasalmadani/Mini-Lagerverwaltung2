unit uLagerService;

{$mode objfpc}{$H+}

interface

uses
  Classes, SysUtils, Variants, sqldb, uArtikel;

const
  { Bewegungsarten, so wie sie in der Datenbank gespeichert werden }
  ART_ZUGANG = 'ZUGANG';   { Wareneingang: erhöht den Bestand }
  ART_ABGANG = 'ABGANG';   { Warenausgang: verringert den Bestand }

type
  { TBewegung
    Eine gebuchte Lagerbewegung (nur Lesen, wird nie geändert). }
  TBewegung = record
    ID: Integer;
    Artikelnummer: string;
    Art: string;            { ART_ZUGANG oder ART_ABGANG }
    Menge: Integer;
    Zeitpunkt: TDateTime;   { Datum und Uhrzeit der Buchung }
    StornoVon: Integer;     { 0 = normale Buchung, sonst ID der stornierten Buchung }
    Bemerkung: string;
  end;

  TBewegungArray = array of TBewegung;

  { TLagerService
    Fachlogik und Datenbankzugriff der Lagerverwaltung.
    - Hält alle Artikel als Objekte im Speicher (FArtikelListe).
    - Schreibt jede Änderung zuerst in die Datenbank.
    - Kennt keine Oberfläche. Fehler werden über Fehlermeldung
      zurückgegeben, damit das Formular sie anzeigen kann.
    Verbindung und Transaktion gehören dem Formular. }
  TLagerService = class
  private
    FArtikelListe: TList;          { Besitzer der TArtikel-Objekte }
    FConn: TSQLConnection;         { gehört dem Formular }
    FTrans: TSQLTransaction;       { gehört dem Formular }

    { Liefert die Position in der Liste oder -1, wenn nicht gefunden }
    function IndexVonArtikelnummer(
      const AArtikelnummer: string
    ): Integer;

    { Lädt alle Artikel beim Start aus der Datenbank }
    procedure ArtikelAusDatenbankLaden;

    { Führt ein INSERT/UPDATE/DELETE mit Parametern aus und
      bestätigt (Commit) oder macht rückgängig (Rollback) }
    procedure SqlAusfuehren(
      const ASql: string;
      const Werte: array of Variant
    );

    { Prüft, ob es zu einem Artikel schon Bewegungen gibt }
    function HatBewegungen(const ANummer: string): Boolean;

    { Bucht eine Bewegung und ändert den Bestand in EINER Transaktion }
    function BuchungDurchfuehren(
      const ANummer, AArt: string;
      AMenge: Integer;
      const ABemerkung: string;
      AStornoVon: Integer;
      out Fehlermeldung: string
    ): Boolean;

  public
    constructor Create(AConn: TSQLConnection; ATrans: TSQLTransaction);
    destructor Destroy; override;

    { ---- Artikelverwaltung ---- }
    function ArtikelHinzufuegen(
      const AArtikelnummer, ABezeichnung: string;
      AEinzelpreis: Double;
      AMindestbestand: Integer;
      out Fehlermeldung: string
    ): Boolean;

    function ArtikelBearbeiten(
      const AArtikelnummer, ABezeichnung: string;
      AEinzelpreis: Double;
      AMindestbestand: Integer;
      out Fehlermeldung: string
    ): Boolean;

    function ArtikelLoeschen(
      const AArtikelnummer: string;
      out Fehlermeldung: string
    ): Boolean;

    function ArtikelSuchen(
      const AArtikelnummer: string
    ): TArtikel;

    function ArtikelAnzahl: Integer;

    function ArtikelAnIndex(
      Index: Integer
    ): TArtikel;

    { ---- Lagerbewegungen ---- }

    { Wareneingang (AZugang = True) oder Warenausgang (False) buchen }
    function BewegungBuchen(
      const ANummer: string;
      AZugang: Boolean;
      AMenge: Integer;
      out Fehlermeldung: string
    ): Boolean;

    { Bewegung durch eine Gegenbuchung ausgleichen.
      Die ursprüngliche Buchung bleibt unverändert erhalten. }
    function BewegungStornieren(
      AID: Integer;
      out Fehlermeldung: string
    ): Boolean;

    { Bewegungen lesen. Leere Artikelnummer = alle Artikel.
      Neueste Bewegungen stehen zuerst. }
    function BewegungenLesen(
      const ANummer: string
    ): TBewegungArray;
  end;

implementation

{ ===================== Aufbau und Abbau ===================== }

constructor TLagerService.Create(
  AConn: TSQLConnection;
  ATrans: TSQLTransaction
);
begin
  inherited Create;
  FArtikelListe := TList.Create;
  FConn := AConn;
  FTrans := ATrans;

  { Verbindung öffnen, falls das Formular sie noch nicht geöffnet hat }
  if not FConn.Connected then
    FConn.Open;

  ArtikelAusDatenbankLaden;
end;

destructor TLagerService.Destroy;
var
  i: Integer;
begin
  { Der Service ist Besitzer der Artikelobjekte und gibt sie frei }
  for i := 0 to FArtikelListe.Count - 1 do
    TArtikel(FArtikelListe[i]).Free;

  FArtikelListe.Free;

  { FConn und FTrans gehören dem Formular und werden hier NICHT freigegeben }
  inherited Destroy;
end;

{ ===================== Datenbank-Hilfsmethoden ===================== }

procedure TLagerService.ArtikelAusDatenbankLaden;
var
  Q: TSQLQuery;
  A: TArtikel;
begin
  Q := TSQLQuery.Create(nil);
  try
    Q.DataBase := FConn;
    Q.Transaction := FTrans;
    Q.SQL.Text :=
      'SELECT ARTIKELNUMMER, BEZEICHNUNG, EINZELPREIS, ' +
      'MINDESTBESTAND, BESTAND FROM ARTIKEL ORDER BY ARTIKELNUMMER';
    Q.Open;

    { Jede Datenbankzeile wird zu einem TArtikel-Objekt }
    while not Q.EOF do
    begin
      A := TArtikel.Create(
        Q.FieldByName('ARTIKELNUMMER').AsString,
        Q.FieldByName('BEZEICHNUNG').AsString,
        Q.FieldByName('EINZELPREIS').AsFloat,
        Q.FieldByName('MINDESTBESTAND').AsInteger
      );
      A.Bestand := Q.FieldByName('BESTAND').AsInteger;
      FArtikelListe.Add(A);
      Q.Next;
    end;
    Q.Close;
  finally
    Q.Free;
  end;

  { Lesetransaktion beenden }
  if FTrans.Active then
    FTrans.Commit;
end;


procedure TLagerService.SqlAusfuehren(
  const ASql: string;
  const Werte: array of Variant
);
var
  Q: TSQLQuery;
  i: Integer;
begin
  Q := TSQLQuery.Create(nil);
  try
    Q.DataBase := FConn;
    Q.Transaction := FTrans;
    Q.SQL.Text := ASql;

    { Parameter in der Reihenfolge einsetzen, wie sie im SQL vorkommen }
    for i := 0 to High(Werte) do
      Q.Params[i].Value := Werte[i];

    try
      Q.ExecSQL;
      FTrans.Commit;
    except
      { Bei einem Fehler alles rückgängig machen und den Fehler
        weitergeben, damit die Oberfläche ihn anzeigen kann }
      if FTrans.Active then
        FTrans.Rollback;
      raise;
    end;
  finally
    Q.Free;
  end;
end;

function TLagerService.IndexVonArtikelnummer(
  const AArtikelnummer: string
): Integer;
var
  i: Integer;
begin
  Result := -1;

  { Vergleich ohne Beachtung von Groß- und Kleinschreibung }
  for i := 0 to FArtikelListe.Count - 1 do
  begin
    if SameText(
      TArtikel(FArtikelListe[i]).Artikelnummer,
      Trim(AArtikelnummer)
    ) then
    begin
      Result := i;
      Exit;
    end;
  end;
end;

function TLagerService.HatBewegungen(const ANummer: string): Boolean;
var
  Q: TSQLQuery;
begin
  Q := TSQLQuery.Create(nil);
  try
    Q.DataBase := FConn;
    Q.Transaction := FTrans;
    Q.SQL.Text :=
      'SELECT COUNT(*) AS ANZ FROM BEWEGUNG WHERE ARTIKELNUMMER = :n';
    Q.ParamByName('n').AsString := ANummer;
    Q.Open;
    Result := Q.FieldByName('ANZ').AsInteger > 0;
    Q.Close;
  finally
    Q.Free;
  end;

  if FTrans.Active then
    FTrans.Commit;
end;

{ ===================== Artikelverwaltung ===================== }

function TLagerService.ArtikelHinzufuegen(
  const AArtikelnummer, ABezeichnung: string;
  AEinzelpreis: Double;
  AMindestbestand: Integer;
  out Fehlermeldung: string
): Boolean;
var
  Artikel: TArtikel;
begin
  Result := False;
  Fehlermeldung := '';

  { ---- Eingaben prüfen ---- }
  if Trim(AArtikelnummer) = '' then
  begin
    Fehlermeldung := 'Bitte eine Artikelnummer eingeben.';
    Exit;
  end;

  if Trim(ABezeichnung) = '' then
  begin
    Fehlermeldung := 'Bitte eine Bezeichnung eingeben.';
    Exit;
  end;

  if AEinzelpreis < 0 then
  begin
    Fehlermeldung := 'Der Preis darf nicht negativ sein.';
    Exit;
  end;

  if AMindestbestand < 0 then
  begin
    Fehlermeldung := 'Der Mindestbestand darf nicht negativ sein.';
    Exit;
  end;

  if IndexVonArtikelnummer(AArtikelnummer) >= 0 then
  begin
    Fehlermeldung := 'Diese Artikelnummer existiert bereits.';
    Exit;
  end;

  Artikel := TArtikel.Create(
    AArtikelnummer,
    ABezeichnung,
    AEinzelpreis,
    AMindestbestand
  );

  try
    { Zuerst in die Datenbank schreiben. Schlägt das fehl, bleibt
      die Liste unverändert und beide Seiten bleiben gleich. }
    SqlAusfuehren(
      'INSERT INTO ARTIKEL (ARTIKELNUMMER, BEZEICHNUNG, EINZELPREIS, ' +
      'MINDESTBESTAND) VALUES (:n, :b, :p, :m)',
      [Artikel.Artikelnummer, Artikel.Bezeichnung,
       AEinzelpreis, AMindestbestand]);

    FArtikelListe.Add(Artikel);
  except
    Artikel.Free;  { kein Speicherleck bei Fehlern }
    raise;
  end;

  Result := True;
end;

function TLagerService.ArtikelBearbeiten(
  const AArtikelnummer, ABezeichnung: string;
  AEinzelpreis: Double;
  AMindestbestand: Integer;
  out Fehlermeldung: string
): Boolean;
var
  Artikel: TArtikel;
begin
  Result := False;
  Fehlermeldung := '';

  Artikel := ArtikelSuchen(AArtikelnummer);

  if Artikel = nil then
  begin
    Fehlermeldung := 'Artikel nicht gefunden.';
    Exit;
  end;

  { ---- Eingaben prüfen ---- }
  if Trim(ABezeichnung) = '' then
  begin
    Fehlermeldung := 'Bitte eine Bezeichnung eingeben.';
    Exit;
  end;

  if AEinzelpreis < 0 then
  begin
    Fehlermeldung := 'Der Preis darf nicht negativ sein.';
    Exit;
  end;

  if AMindestbestand < 0 then
  begin
    Fehlermeldung := 'Der Mindestbestand darf nicht negativ sein.';
    Exit;
  end;

  { Zuerst die Datenbank ändern. Der Bestand wird hier bewusst
    nicht angefasst, er ändert sich nur durch Buchungen. }
  SqlAusfuehren(
    'UPDATE ARTIKEL SET BEZEICHNUNG = :b, EINZELPREIS = :p, ' +
    'MINDESTBESTAND = :m WHERE ARTIKELNUMMER = :n',
    [Trim(ABezeichnung), AEinzelpreis, AMindestbestand,
     Artikel.Artikelnummer]);

  { Danach das Objekt im Speicher angleichen }
  Artikel.Bezeichnung := Trim(ABezeichnung);
  Artikel.Einzelpreis := AEinzelpreis;
  Artikel.Mindestbestand := AMindestbestand;

  Result := True;
end;

function TLagerService.ArtikelLoeschen(
  const AArtikelnummer: string;
  out Fehlermeldung: string
): Boolean;
var
  Index: Integer;
  Artikel: TArtikel;
begin
  Result := False;
  Fehlermeldung := '';

  Index := IndexVonArtikelnummer(AArtikelnummer);

  { 1. Existiert der Artikel? Erst danach darf auf die Liste
       zugegriffen werden. }
  if Index < 0 then
  begin
    Fehlermeldung := 'Artikel nicht gefunden.';
    Exit;
  end;

  { 2. Artikel mit Bewegungen dürfen nicht gelöscht werden,
       sonst gingen die Buchungen verloren. }
  if HatBewegungen(TArtikel(FArtikelListe[Index]).Artikelnummer) then
  begin
    Fehlermeldung :=
      'Der Artikel hat gebuchte Bewegungen und kann nicht gelöscht werden.';
    Exit;
  end;

  { 3. Zuerst aus der Datenbank löschen, dann aus dem Speicher }
  SqlAusfuehren(
    'DELETE FROM ARTIKEL WHERE ARTIKELNUMMER = :n',
    [TArtikel(FArtikelListe[Index]).Artikelnummer]);

  Artikel := TArtikel(FArtikelListe[Index]);
  FArtikelListe.Delete(Index);
  Artikel.Free;

  Result := True;
end;

function TLagerService.ArtikelSuchen(
  const AArtikelnummer: string
): TArtikel;
var
  Index: Integer;
begin
  Index := IndexVonArtikelnummer(AArtikelnummer);

  if Index >= 0 then
    Result := TArtikel(FArtikelListe[Index])
  else
    Result := nil;
end;

function TLagerService.ArtikelAnzahl: Integer;
begin
  Result := FArtikelListe.Count;
end;

function TLagerService.ArtikelAnIndex(
  Index: Integer
): TArtikel;
begin
  { Ungültige Positionen liefern nil statt eines Absturzes }
  if (Index < 0) or (Index >= FArtikelListe.Count) then
    Result := nil
  else
    Result := TArtikel(FArtikelListe[Index]);
end;

{ ===================== Lagerbewegungen ===================== }

function TLagerService.BuchungDurchfuehren(
  const ANummer, AArt: string;
  AMenge: Integer;
  const ABemerkung: string;
  AStornoVon: Integer;
  out Fehlermeldung: string
): Boolean;
var
  Q: TSQLQuery;
  Artikel: TArtikel;
  Delta: Integer;   { positiv bei Zugang, negativ bei Abgang }
begin
  Result := False;
  Fehlermeldung := '';

  Artikel := ArtikelSuchen(ANummer);
  if Artikel = nil then
  begin
    Fehlermeldung := 'Artikel nicht gefunden.';
    Exit;
  end;

  if AMenge <= 0 then
  begin
    Fehlermeldung := 'Die Menge muss größer als 0 sein.';
    Exit;
  end;

  if AArt = ART_ZUGANG then
    Delta := AMenge
  else
    Delta := -AMenge;

  Q := TSQLQuery.Create(nil);
  try
    Q.DataBase := FConn;
    Q.Transaction := FTrans;
    try
      { Schritt 1: Bestand ändern, aber nur, wenn er nicht negativ wird.
        Ist die Bedingung nicht erfüllt, ändert das UPDATE keine Zeile. }
      Q.SQL.Text :=
        'UPDATE ARTIKEL SET BESTAND = BESTAND + :d ' +
        'WHERE ARTIKELNUMMER = :n AND BESTAND + :d >= 0';
      Q.ParamByName('d').AsInteger := Delta;
      Q.ParamByName('n').AsString := Artikel.Artikelnummer;
      Q.ExecSQL;

      if Q.RowsAffected = 0 then
      begin
        FTrans.Rollback;
        Fehlermeldung :=
          'Der Bestand würde negativ werden. Aktueller Bestand: ' +
          IntToStr(Artikel.Bestand);
        Exit;
      end;

      { Schritt 2: Bewegung speichern. Das Datum mit Uhrzeit setzt die
        Datenbank selbst (CURRENT_TIMESTAMP). }
      Q.SQL.Text :=
        'INSERT INTO BEWEGUNG (ARTIKELNUMMER, BEWEGUNGSART, MENGE, ' +
        'STORNO_VON, BEMERKUNG) VALUES (:n, :a, :m, :s, :b)';
      Q.ParamByName('n').AsString := Artikel.Artikelnummer;
      Q.ParamByName('a').AsString := AArt;
      Q.ParamByName('m').AsInteger := AMenge;

      { Bei normalen Buchungen bleibt STORNO_VON leer (NULL) }
      if AStornoVon > 0 then
        Q.ParamByName('s').AsInteger := AStornoVon
      else
        Q.ParamByName('s').Clear;

      Q.ParamByName('b').AsString := ABemerkung;
      Q.ExecSQL;

      { Beides zusammen bestätigen: Bestand und Bewegung gehören
        immer zusammen. }
      FTrans.Commit;
    except
      if FTrans.Active then
        FTrans.Rollback;
      raise;
    end;
  finally
    Q.Free;
  end;

  { Erst nach erfolgreichem Commit das Objekt im Speicher angleichen }
  Artikel.Bestand := Artikel.Bestand + Delta;
  Result := True;
end;

function TLagerService.BewegungBuchen(
  const ANummer: string;
  AZugang: Boolean;
  AMenge: Integer;
  out Fehlermeldung: string
): Boolean;
var
  Art: string;
begin
  if AZugang then
    Art := ART_ZUGANG
  else
    Art := ART_ABGANG;

  { Normale Buchung: keine Bemerkung, kein Storno-Bezug (0) }
  Result := BuchungDurchfuehren(
    ANummer, Art, AMenge, '', 0, Fehlermeldung);
end;

function TLagerService.BewegungStornieren(
  AID: Integer;
  out Fehlermeldung: string
): Boolean;
var
  Q: TSQLQuery;
  Gefunden, IstStorno, SchonStorniert: Boolean;
  Nummer, Art, Gegenart: string;
  Menge: Integer;
begin
  Result := False;
  Fehlermeldung := '';
  Gefunden := False;
  IstStorno := False;
  SchonStorniert := False;
  Nummer := '';
  Art := '';
  Menge := 0;

  { Die ursprüngliche Buchung lesen und prüfen, ob sie schon
    storniert wurde }
  Q := TSQLQuery.Create(nil);
  try
    Q.DataBase := FConn;
    Q.Transaction := FTrans;
    Q.SQL.Text :=
      'SELECT B.ARTIKELNUMMER, B.BEWEGUNGSART, B.MENGE, B.STORNO_VON, ' +
      '(SELECT COUNT(*) FROM BEWEGUNG S WHERE S.STORNO_VON = B.ID) AS ANZ ' +
      'FROM BEWEGUNG B WHERE B.ID = :id';
    Q.ParamByName('id').AsInteger := AID;
    Q.Open;

    Gefunden := not Q.EOF;
    if Gefunden then
    begin
      Nummer := Q.FieldByName('ARTIKELNUMMER').AsString;
      Art := Q.FieldByName('BEWEGUNGSART').AsString;
      Menge := Q.FieldByName('MENGE').AsInteger;
      IstStorno := not Q.FieldByName('STORNO_VON').IsNull;
      SchonStorniert := Q.FieldByName('ANZ').AsInteger > 0;
    end;
    Q.Close;
  finally
    Q.Free;
  end;

  if FTrans.Active then
    FTrans.Commit;

  { ---- Regeln für das Stornieren ---- }
  if not Gefunden then
  begin
    Fehlermeldung := 'Bewegung nicht gefunden.';
    Exit;
  end;

  if IstStorno then
  begin
    Fehlermeldung := 'Eine Storno-Buchung kann nicht storniert werden.';
    Exit;
  end;

  if SchonStorniert then
  begin
    Fehlermeldung := 'Diese Bewegung wurde bereits storniert.';
    Exit;
  end;

  { Die Gegenbuchung hat die umgekehrte Bewegungsart und dieselbe
    Menge. Sie verweist über AID auf die ursprüngliche Buchung. }
  if Art = ART_ZUGANG then
    Gegenart := ART_ABGANG
  else
    Gegenart := ART_ZUGANG;

  Result := BuchungDurchfuehren(
    Nummer, Gegenart, Menge,
    'Storno zu Buchung ' + IntToStr(AID), AID, Fehlermeldung);
end;

function TLagerService.BewegungenLesen(
  const ANummer: string
): TBewegungArray;
var
  Q: TSQLQuery;
  n: Integer;
begin
  SetLength(Result, 0);

  Q := TSQLQuery.Create(nil);
  try
    Q.DataBase := FConn;
    Q.Transaction := FTrans;

    { SQL zusammenbauen: mit Filter nur, wenn eine Artikelnummer
      angegeben wurde }
    Q.SQL.Text :=
      'SELECT ID, ARTIKELNUMMER, BEWEGUNGSART, MENGE, ZEITPUNKT, ' +
      'STORNO_VON, BEMERKUNG FROM BEWEGUNG ';
    if Trim(ANummer) <> '' then
      Q.SQL.Text := Q.SQL.Text + 'WHERE ARTIKELNUMMER = :n ';
    Q.SQL.Text := Q.SQL.Text + 'ORDER BY ZEITPUNKT DESC, ID DESC';

    if Trim(ANummer) <> '' then
      Q.ParamByName('n').AsString := Trim(ANummer);

    Q.Open;
    while not Q.EOF do
    begin
      n := Length(Result);
      SetLength(Result, n + 1);

      Result[n].ID := Q.FieldByName('ID').AsInteger;
      Result[n].Artikelnummer := Q.FieldByName('ARTIKELNUMMER').AsString;
      Result[n].Art := Q.FieldByName('BEWEGUNGSART').AsString;
      Result[n].Menge := Q.FieldByName('MENGE').AsInteger;
      Result[n].Zeitpunkt := Q.FieldByName('ZEITPUNKT').AsDateTime;
      Result[n].StornoVon := Q.FieldByName('STORNO_VON').AsInteger;  { NULL ergibt 0 }
      Result[n].Bemerkung := Q.FieldByName('BEMERKUNG').AsString;

      Q.Next;
    end;
    Q.Close;
  finally
    Q.Free;
  end;

  if FTrans.Active then
    FTrans.Commit;
end;

end.
