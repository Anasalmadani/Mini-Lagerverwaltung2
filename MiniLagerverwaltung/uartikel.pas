unit uArtikel;

{$mode objfpc}{$H+}

interface

uses
  SysUtils;

type
  { TArtikel
    Datenklasse für einen Lagerartikel.
    Sie enthält keine Oberfläche und keinen Datenbankzugriff,
    nur die Daten eines Artikels. Das Laden und Speichern
    übernimmt TLagerService. }
  TArtikel = class
  private
    FArtikelnummer: string;    { eindeutiger Schlüssel, nach dem Anlegen fest }
    FBezeichnung: string;      { Name oder Beschreibung des Artikels }
    FEinzelpreis: Double;      { Preis pro Stück }
    FMindestbestand: Integer;  { darunter sollte nachbestellt werden }
    FBestand: Integer;         { aktueller Lagerbestand }

  public
    { Legt einen neuen Artikel an.
      Der Bestand startet immer bei 0 und ändert sich danach
      nur durch Buchungen (Wareneingang und Warenausgang). }
    constructor Create(
      const AArtikelnummer: string;
      const ABezeichnung: string;
      AEinzelpreis: Double;
      AMindestbestand: Integer
    );

    { Nur lesbar: Die Artikelnummer darf nachträglich nicht
      geändert werden, weil Bewegungen darauf verweisen. }
    property Artikelnummer: string
      read FArtikelnummer;

    { Lesbar und änderbar }
    property Bezeichnung: string
      read FBezeichnung write FBezeichnung;
    property Einzelpreis: Double
      read FEinzelpreis write FEinzelpreis;
    property Mindestbestand: Integer
      read FMindestbestand write FMindestbestand;

    { Wird nur von TLagerService gesetzt: beim Laden aus der
      Datenbank und nach einer erfolgreichen Buchung }
    property Bestand: Integer
      read FBestand write FBestand;
  end;

implementation

constructor TArtikel.Create(
  const AArtikelnummer: string;
  const ABezeichnung: string;
  AEinzelpreis: Double;
  AMindestbestand: Integer
);
begin
  inherited Create;

  { Leerzeichen am Anfang und Ende entfernen, damit
    ' A1 ' und 'A1' dieselbe Nummer sind }
  FArtikelnummer := Trim(AArtikelnummer);
  FBezeichnung := Trim(ABezeichnung);
  FEinzelpreis := AEinzelpreis;
  FMindestbestand := AMindestbestand;

  { Neuer Artikel: noch keine Ware im Lager }
  FBestand := 0;
end;

end.
