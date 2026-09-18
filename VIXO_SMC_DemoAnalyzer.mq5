//+------------------------------------------------------------------+
//| VIXO_SMC_DemoAnalyzer.mq5                                        |
//| VIXO - deterministic SMC analyzer + demo/Strategy Tester EA     |
//| M15 structure -> liquidity -> BOS/MSS -> OB/FVG -> M5 confirm   |
//+------------------------------------------------------------------+
#property strict
#property version   "1.00"
#property description "VIXO SMC Demo Analyzer. Demo/Strategy Tester only."

#include <Trade/Trade.mqh>

CTrade trade;

//--------------------------- Inputs ---------------------------------
input string InpSupabaseUrl   = "https://coppwuqtxplzdcqzeoxj.supabase.co";
input string InpSupabaseKey   = "sb_publishable_5qUeiFWGWkcfpiBKyCXp8g_IUPzMOmb";
input int    InpPollSeconds   = 15;
input long   InpMagic         = 26091801;

input bool   InpAutoTrading   = false; // keep false until tested
input string InpSymbol        = "XAUUSD";
input double InpLot           = 0.01;
input int    InpMaxPositions  = 1;
input double InpRR            = 2.0;

input int    InpStructureBars  = 80;
input int    InpConfirmBars    = 30;
input int    InpSwingStrength  = 2;
input int    InpZoneLookback   = 20;
input double InpSLBufferPoints = 50.0;

input bool   InpRequireSweep   = true;
input bool   InpRequireFVG     = false;
input bool   InpUseSupabase    = true;

//--------------------------- State ----------------------------------
datetime g_lastM5Bar = 0;
datetime g_lastM15Bar = 0;
string   g_lastSignal = "WAIT";
string   g_lastAction = "NONE";
string   g_lastMessage = "Menunggu analisis SMC.";
string   g_lastArea = "-";
string   g_lastConfirm = "-";
double   g_lastEntry = 0.0;
double   g_lastSL = 0.0;
double   g_lastTP = 0.0;

struct SMCSetup
{
   int direction;       // 1 buy, -1 sell, 0 none
   bool bos;
   bool sweep;
   bool fvg;
   bool confirmation;
   double structureLevel;
   double zoneHigh;
   double zoneLow;
   double entry;
   double sl;
   double tp;
   string area;
   string confirmText;
   string reason;
};

//--------------------------- Helpers --------------------------------
string JsonEscape(string s)
{
   StringReplace(s, "\\", "\\\\");
   StringReplace(s, "\"", "\\\"");
   StringReplace(s, "\r", "");
   StringReplace(s, "\n", " ");
   return s;
}

bool IsAllowedRuntime()
{
   // Hard guard: this EA is intentionally restricted to demo/tester.
   if(MQLInfoInteger(MQL_TESTER))
      return true;

   long mode = AccountInfoInteger(ACCOUNT_TRADE_MODE);
   if(mode == ACCOUNT_TRADE_MODE_DEMO)
      return true;

   Print("VIXO SMC: LIVE account detected. Trading disabled by design.");
   return false;
}

int CountOurPositions()
{
   int count = 0;
   for(int i=PositionsTotal()-1; i>=0; i--)
   {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0) continue;

      if(PositionGetString(POSITION_SYMBOL) == _Symbol &&
         (long)PositionGetInteger(POSITION_MAGIC) == InpMagic)
         count++;
   }
   return count;
}

double NormalizePrice(double price)
{
   int digits = (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS);
   return NormalizeDouble(price, digits);
}

double NormalizeLot(double lot)
{
   double minLot = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
   double maxLot = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX);
   double step   = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);

   lot = MathMax(minLot, MathMin(maxLot, lot));
   if(step > 0)
      lot = MathFloor(lot/step)*step;

   int vd = 2;
   if(step == 1.0) vd = 0;
   else if(step == 0.1) vd = 1;
   else if(step == 0.01) vd = 2;

   return NormalizeDouble(lot, vd);
}

bool CopyRatesSafe(string symbol, ENUM_TIMEFRAMES tf, int count, MqlRates &rates[])
{
   ArraySetAsSeries(rates, true);
   int copied = CopyRates(symbol, tf, 0, count, rates);
   return (copied >= count);
}

bool IsSwingHigh(MqlRates &r[], int i, int strength)
{
   int n = ArraySize(r);
   if(i-strength < 1 || i+strength >= n) return false;

   for(int k=1; k<=strength; k++)
   {
      if(r[i].high <= r[i-k].high || r[i].high <= r[i+k].high)
         return false;
   }
   return true;
}

bool IsSwingLow(MqlRates &r[], int i, int strength)
{
   int n = ArraySize(r);
   if(i-strength < 1 || i+strength >= n) return false;

   for(int k=1; k<=strength; k++)
   {
      if(r[i].low >= r[i-k].low || r[i].low >= r[i+k].low)
         return false;
   }
   return true;
}

bool GetRecentSwingLevels(MqlRates &r[], double &lastHigh, double &lastLow,
                          int &highIndex, int &lowIndex)
{
   lastHigh = 0.0;
   lastLow = 0.0;
   highIndex = -1;
   lowIndex = -1;

   int n = ArraySize(r);
   for(int i=InpSwingStrength+1; i<n-InpSwingStrength; i++)
   {
      if(highIndex < 0 && IsSwingHigh(r,i,InpSwingStrength))
      {
         highIndex = i;
         lastHigh = r[i].high;
      }

      if(lowIndex < 0 && IsSwingLow(r,i,InpSwingStrength))
      {
         lowIndex = i;
         lastLow = r[i].low;
      }

      if(highIndex >= 0 && lowIndex >= 0)
         break;
   }
   return (highIndex >= 0 && lowIndex >= 0);
}

bool DetectBOS(MqlRates &r[], int &direction, double &level)
{
   direction = 0;
   level = 0.0;

   double sh, sl;
   int hi, lo;
   if(!GetRecentSwingLevels(r,sh,sl,hi,lo))
      return false;

   // Use the last completed M15 candle (index 1).
   double close1 = r[1].close;

   if(close1 > sh)
   {
      direction = 1;
      level = sh;
      return true;
   }

   if(close1 < sl)
   {
      direction = -1;
      level = sl;
      return true;
   }

   return false;
}

bool DetectSweep(MqlRates &r[], int direction)
{
   // Sweep = wick through a recent liquidity swing, followed by close back.
   double sh, sl;
   int hi, lo;
   if(!GetRecentSwingLevels(r,sh,sl,hi,lo))
      return false;

   MqlRates c = r[1];

   if(direction > 0)
   {
      // Bullish setup: sell-side liquidity below swing low is swept.
      return (c.low < sl && c.close > sl);
   }

   if(direction < 0)
   {
      // Bearish setup: buy-side liquidity above swing high is swept.
      return (c.high > sh && c.close < sh);
   }

   return false;
}

bool FindOrderBlock(MqlRates &r[], int direction, double &zoneLow, double &zoneHigh)
{
   zoneLow = 0.0;
   zoneHigh = 0.0;

   int n = ArraySize(r);
   int maxI = MathMin(InpZoneLookback, n-3);

   // Last opposite candle before the displacement/BOS.
   for(int i=2; i<=maxI; i++)
   {
      bool bearish = (r[i].close < r[i].open);
      bool bullish = (r[i].close > r[i].open);

      if(direction > 0 && bearish)
      {
         zoneLow = r[i].low;
         zoneHigh = r[i].open;
         return true;
      }

      if(direction < 0 && bullish)
      {
         zoneLow = r[i].open;
         zoneHigh = r[i].high;
         return true;
      }
   }
   return false;
}

bool DetectFVG(MqlRates &r[], int direction, double &fvgLow, double &fvgHigh)
{
   fvgLow = 0.0;
   fvgHigh = 0.0;

   int n = ArraySize(r);
   int maxI = MathMin(InpConfirmBars, n-4);

   // Three-candle FVG on completed candles:
   // bullish: older high < newer low
   // bearish: older low > newer high
   for(int i=1; i<=maxI; i++)
   {
      MqlRates newer = r[i];
      MqlRates middle = r[i+1];
      MqlRates older = r[i+2];

      if(direction > 0 && newer.low > older.high)
      {
         fvgLow = older.high;
         fvgHigh = newer.low;
         return true;
      }

      if(direction < 0 && newer.high < older.low)
      {
         fvgLow = newer.high;
         fvgHigh = older.low;
         return true;
      }
   }
   return false;
}

bool M5Confirmation(int direction)
{
   MqlRates r[];
   if(!CopyRatesSafe(_Symbol, PERIOD_M5, InpConfirmBars+5, r))
      return false;

   MqlRates c1 = r[1];
   MqlRates c2 = r[2];

   if(direction > 0)
   {
      bool bullishCandle = c1.close > c1.open;
      bool breakHigh = c1.close > c2.high;
      bool engulf = (c1.close > c2.open && c1.open <= c2.close);

      return bullishCandle && (breakHigh || engulf);
   }

   if(direction < 0)
   {
      bool bearishCandle = c1.close < c1.open;
      bool breakLow = c1.close < c2.low;
      bool engulf = (c1.close < c2.open && c1.open >= c2.close);

      return bearishCandle && (breakLow || engulf);
   }

   return false;
}

bool PriceInZone(double price, double low, double high)
{
   if(low > high)
   {
      double t=low; low=high; high=t;
   }
   return price >= low && price <= high;
}

SMCSetup AnalyzeSMC()
{
   SMCSetup s;
   s.direction=0;
   s.bos=false; s.sweep=false; s.fvg=false; s.confirmation=false;
   s.structureLevel=0; s.zoneHigh=0; s.zoneLow=0;
   s.entry=0; s.sl=0; s.tp=0;
   s.area="-"; s.confirmText="-"; s.reason="No valid SMC setup.";

   MqlRates m15[];
   if(!CopyRatesSafe(_Symbol, PERIOD_M15, InpStructureBars+10, m15))
   {
      s.reason="M15 data belum cukup.";
      return s;
   }

   int dir=0;
   double level=0;
   if(!DetectBOS(m15,dir,level))
   {
      s.reason="Belum ada BOS M15 yang terdeteksi.";
      return s;
   }

   s.direction=dir;
   s.bos=true;
   s.structureLevel=level;

   // OB is the primary POI.
   double obLow, obHigh;
   bool hasOB = FindOrderBlock(m15,dir,obLow,obHigh);
   if(!hasOB)
   {
      s.reason="BOS ada, tetapi OB M15 tidak ditemukan.";
      return s;
   }

   s.zoneLow=obLow;
   s.zoneHigh=obHigh;
   s.area = (dir>0 ? "Bullish OB" : "Bearish OB");

   // Liquidity sweep is optional only when disabled by input.
   s.sweep=DetectSweep(m15,dir);
   if(InpRequireSweep && !s.sweep)
   {
      s.reason="BOS ada, tetapi liquidity sweep belum terkonfirmasi.";
      return s;
   }

   MqlRates m5[];
   if(!CopyRatesSafe(_Symbol, PERIOD_M5, InpConfirmBars+8, m5))
   {
      s.reason="M5 data belum cukup.";
      return s;
   }

   double fvgLow,fvgHigh;
   s.fvg=DetectFVG(m5,dir,fvgLow,fvgHigh);

   if(InpRequireFVG && !s.fvg)
   {
      s.reason="FVG belum ditemukan.";
      return s;
   }

   s.confirmation=M5Confirmation(dir);
   s.confirmText = s.confirmation
      ? (dir>0 ? "M5 bullish confirmation" : "M5 bearish confirmation")
      : "Menunggu confirmation M5";

   double bid=SymbolInfoDouble(_Symbol,SYMBOL_BID);
   double ask=SymbolInfoDouble(_Symbol,SYMBOL_ASK);
   double price=(dir>0 ? ask : bid);

   // Entry is only considered when price is inside the M15 OB.
   if(!PriceInZone(price,obLow,obHigh))
   {
      s.reason="POI/OB terdeteksi, tetapi harga belum kembali ke area.";
      return s;
   }

   if(!s.confirmation)
   {
      s.reason="Harga berada di POI, tetapi confirmation M5 belum ada.";
      return s;
   }

   s.entry=price;

   if(dir>0)
   {
      s.sl = NormalizePrice(obLow - InpSLBufferPoints*_Point);
      double risk = s.entry-s.sl;
      s.tp = NormalizePrice(s.entry + risk*g_rr);
   }
   else
   {
      s.sl = NormalizePrice(obHigh + InpSLBufferPoints*_Point);
      double risk = s.sl-s.entry;
      s.tp = NormalizePrice(s.entry - risk*g_rr);
   }

   if(s.sl<=0 || s.tp<=0)
   {
      s.direction=0;
      s.reason="SL/TP tidak valid.";
      return s;
   }

   s.reason = (dir>0
      ? "M15 bullish BOS + sell-side sweep + OB POI + M5 confirmation."
      : "M15 bearish BOS + buy-side sweep + OB POI + M5 confirmation.");

   return s;
}

//------------------------- Supabase ---------------------------------
bool SupabaseRequest(string method, string endpoint, string body, string &response)
{
   if(!InpUseSupabase || StringLen(InpSupabaseUrl)==0 || StringLen(InpSupabaseKey)==0)
      return false;

   string url = InpSupabaseUrl + endpoint;
   string headers =
      "apikey: " + InpSupabaseKey + "\r\n" +
      "Authorization: Bearer " + InpSupabaseKey + "\r\n" +
      "Content-Type: application/json\r\n" +
      "Prefer: return=minimal\r\n";

   char data[];
   char result[];
   string resultHeaders;

   StringToCharArray(body,data,0,WHOLE_ARRAY,CP_UTF8);

   ResetLastError();
   int code=WebRequest(method,url,headers,5000,data,result,resultHeaders);

   if(code<0)
   {
      Print("VIXO Supabase WebRequest error: ",GetLastError());
      response="";
      return false;
   }

   response=CharArrayToString(result,0,-1,CP_UTF8);
   return (code>=200 && code<300);
}

void PublishStatus(string status, string message)
{
   string symbol = _Symbol;
   string accountMode = (MQLInfoInteger(MQL_TESTER) ? "TESTER" :
                         (AccountInfoInteger(ACCOUNT_TRADE_MODE)==ACCOUNT_TRADE_MODE_DEMO ? "DEMO" : "LIVE_BLOCKED"));

   string body = StringFormat(
      "{\"id\":1,\"status\":\"%s\",\"symbol\":\"%s\",\"account_mode\":\"%s\",\"last_signal\":\"%s\",\"last_action\":\"%s\",\"message\":\"%s\"}",
      JsonEscape(status),
      JsonEscape(symbol),
      JsonEscape(accountMode),
      JsonEscape(g_lastSignal),
      JsonEscape(g_lastAction),
      JsonEscape(message)
   );

   string response;
   SupabaseRequest("POST","/rest/v1/vixo_bot_status?on_conflict=id",body,response);
}

void LoadSettings()
{
   // The EA keeps safe local defaults if the remote settings cannot be read.
   string response;
   if(!SupabaseRequest("GET","/rest/v1/vixo_bot_settings?id=eq.1&select=*", "", response))
      return;

   // Lightweight parsing intentionally avoids external JSON libraries.
   string v;
   int p;

   p=StringFind(response,"\"enabled\":");
   if(p>=0)
   {
      int e=StringFind(response,",",p);
      v=StringSubstr(response,p+10,(e>p ? e-(p+10) : 5));
      StringTrimLeft(v); StringTrimRight(v);
      g_enabled=(v=="true");
   }

   p=StringFind(response,"\"lot\":");
   if(p>=0)
   {
      int e=StringFind(response,",",p);
      v=StringSubstr(response,p+6,(e>p ? e-(p+6) : 10));
      StringTrimLeft(v); StringTrimRight(v);
      double x=StringToDouble(v);
      if(x>0) g_lot=x;
   }

   p=StringFind(response,"\"max_positions\":");
   if(p>=0)
   {
      int e=StringFind(response,",",p);
      v=StringSubstr(response,p+16,(e>p ? e-(p+16) : 10));
      StringTrimLeft(v); StringTrimRight(v);
      int x=(int)StringToInteger(v);
      if(x>0) g_maxPositions=x;
   }

   p=StringFind(response,"\"rr\":");
   if(p>=0)
   {
      int e=StringFind(response,",",p);
      v=StringSubstr(response,p+5,(e>p ? e-(p+5) : 10));
      StringTrimLeft(v); StringTrimRight(v);
      double x=StringToDouble(v);
      if(x>0) g_rr=x;
   }
}

//------------------------- Execution --------------------------------
bool OpenDemoTrade(const SMCSetup &s)
{
   if(!g_enabled)
   {
      g_lastAction="ANALYSIS ONLY";
      return false;
   }

   if(!IsAllowedRuntime())
   {
      g_lastAction="LIVE BLOCKED";
      g_lastMessage="LIVE account terdeteksi. Trading diblokir.";
      return false;
   }

   if(CountOurPositions() >= g_maxPositions)
   {
      g_lastAction="MAX POSITIONS";
      g_lastMessage="Batas posisi tercapai.";
      return false;
   }

   double lot=NormalizeLot(g_lot);
   trade.SetExpertMagicNumber(InpMagic);
   trade.SetDeviationInPoints(30);

   bool ok=false;
   if(s.direction>0)
      ok=trade.Buy(lot,_Symbol,0.0,s.sl,s.tp,"VIXO SMC BUY");
   else if(s.direction<0)
      ok=trade.Sell(lot,_Symbol,0.0,s.sl,s.tp,"VIXO SMC SELL");

   if(ok)
   {
      g_lastAction=(s.direction>0 ? "BUY OPENED" : "SELL OPENED");
      g_lastMessage="Demo/tester order dibuka dari setup SMC.";
   }
   else
   {
      g_lastAction="ORDER FAILED";
      g_lastMessage="Order gagal: "+trade.ResultRetcodeDescription();
   }

   return ok;
}

void RunAnalysis()
{
   SMCSetup s=AnalyzeSMC();

   if(s.direction==0)
      g_lastSignal="WAIT";
   else
      g_lastSignal=(s.direction>0 ? "BUY" : "SELL");

   g_lastArea=s.area;
   g_lastConfirm=s.confirmText;
   g_lastEntry=s.entry;
   g_lastSL=s.sl;
   g_lastTP=s.tp;
   g_lastMessage=s.reason;

   if(s.direction!=0 && s.confirmation)
      OpenDemoTrade(s);
   else
      g_lastAction="WAIT";

   string status = (s.direction!=0 && s.confirmation) ? "SIGNAL" : "WAIT";
   PublishStatus(status,g_lastMessage);
}

//-------------------------- Events ----------------------------------
int OnInit()
{
   if(_Symbol != InpSymbol && InpSymbol!="")
      Print("VIXO SMC: chart symbol=",_Symbol," ; configured symbol=",InpSymbol);

   if(!IsAllowedRuntime())
   {
      g_lastMessage="LIVE account terdeteksi. EA hanya demo/tester.";
      PublishStatus("OFFLINE",g_lastMessage);
      return INIT_SUCCEEDED;
   }

   g_enabled=InpAutoTrading;
   g_lot=InpLot;
   g_maxPositions=InpMaxPositions;
   g_rr=InpRR;

   EventSetTimer(MathMax(5,InpPollSeconds));

   g_lastMessage="VIXO SMC aktif. Menunggu data M15/M5.";
   PublishStatus("ONLINE",g_lastMessage);
   return INIT_SUCCEEDED;
}

void OnDeinit(const int reason)
{
   EventKillTimer();
   PublishStatus("OFFLINE","VIXO SMC dihentikan.");
}

void OnTimer()
{
   if(!IsAllowedRuntime())
   {
      g_lastSignal="WAIT";
      g_lastAction="LIVE BLOCKED";
      g_lastMessage="LIVE account terdeteksi. Trading diblokir.";
      PublishStatus("OFFLINE",g_lastMessage);
      return;
   }

   LoadSettings();

   datetime m5=iTime(_Symbol,PERIOD_M5,0);
   datetime m15=iTime(_Symbol,PERIOD_M15,0);

   // Analyze once per new M5 candle; status still refreshes on timer.
   if(m5!=g_lastM5Bar)
   {
      g_lastM5Bar=m5;
      RunAnalysis();
      g_lastM15Bar=m15;
   }
   else
   {
      PublishStatus("ONLINE",g_lastMessage);
   }
}

void OnTick()
{
   // Execution is deliberately handled on the timer after closed-candle
   // analysis, reducing repeated entries from the same candle.
}
