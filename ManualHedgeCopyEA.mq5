//+------------------------------------------------------------------+
//|                                        ManualHedgeCopyEA.mq5     |
//|  Manual market hedge copier with millisecond polling.            |
//|                                                                  |
//|  Loss formulas shown on both terminals:                          |
//|    Signal SELL hedge entry cost = signal_bid - follower_ask      |
//|    Signal BUY  hedge entry cost = follower_bid - signal_ask      |
//|                                                                  |
//|  Attach this same EA to both terminals. Set one side as SIGNAL    |
//|  and the other side as FOLLOWER. Both terminals must share the    |
//|  same MT5 common files folder on the same VPS/Windows user.       |
//+------------------------------------------------------------------+
#property strict
#property version "1.00"

enum COPY_ROLE
{
   ROLE_SIGNAL   = 0,
   ROLE_FOLLOWER = 1
};

input group "=== Role / Channel ==="
input COPY_ROLE InpRole              = ROLE_SIGNAL;
input string    InpChannel           = "manual_hedge_01";
input int       InpTimerMs           = 10;

input group "=== Trading ==="
input double    InpSignalLot         = 0.01;
input double    InpFollowerLot       = 0.01;
input bool      InpFollowerUseSignalLot = false;
input bool      InpSelfTradeOnSignal = true;
input bool      InpSelfCloseOnSignal = true;
input bool      InpFollowerHedgeMode = true;     // true: signal BUY -> follower SELL, signal SELL -> follower BUY
input int       InpDeviationPoints   = 30;
input int       InpMagicSignal       = 2026061701;
input int       InpMagicFollower     = 2026061702;

input group "=== Auto Loss Switch ==="
input double    InpBuySetLoss        = 0.0;
input double    InpSellSetLoss       = 0.0;
input double    InpCloseBuySetLoss   = 0.0;
input double    InpCloseSellSetLoss  = 0.0;

input group "=== Risk Guard ==="
input bool      InpBlockIfPeerQuoteStale = true;
input int       InpMaxPeerQuoteAgeMs     = 500;
input bool      InpBlockStaleCommand     = false;
input int       InpMaxCommandAgeMs       = 2000;
input bool      InpBlockDuplicateSignal  = true;

input group "=== Panel ==="
input int       InpPanelX            = 15;
input int       InpPanelY            = 30;

struct QuotePacket
{
   long   ts_msc;
   string symbol;
   double bid;
   double ask;
   bool   valid;
};

struct CommandPacket
{
   long   id;
   long   ts_msc;
   string symbol;
   string side;
   double signal_bid;
   double signal_ask;
   double signal_lot;
   double follower_lot;
   bool   valid;
};

const string PFX = "MHC_";
const int    PANEL_W = 360;
const int    ROW_H = 24;

string g_selfQuoteFile = "";
string g_peerQuoteFile = "";
string g_commandFile = "";
QuotePacket g_peerQuote;
long g_lastCommandId = 0;
long g_lastSentId = 0;
string g_status = "Starting";
color g_statusColor = C'130,180,230';
bool g_buySwitch = false;
bool g_sellSwitch = false;
bool g_closeBuySwitch = false;
bool g_closeSellSwitch = false;

int OnInit()
{
   if(InpTimerMs < 1)
   {
      Print("[ManualHedgeCopyEA] InpTimerMs must be >= 1");
      return INIT_PARAMETERS_INCORRECT;
   }

   string roleName = (InpRole == ROLE_SIGNAL) ? "sig" : "fol";
   string peerName = (InpRole == ROLE_SIGNAL) ? "fol" : "sig";
   g_selfQuoteFile = InpChannel + "_" + roleName + "_quote.csv";
   g_peerQuoteFile = InpChannel + "_" + peerName + "_quote.csv";
   g_commandFile   = InpChannel + "_command.csv";

   g_peerQuote.valid = false;

   BuildPanel();
   RefreshSwitchButtons();
   if(!EventSetMillisecondTimer(InpTimerMs))
   {
      Print("[ManualHedgeCopyEA] Millisecond timer failed, fallback to 1 second timer. err=", GetLastError());
      EventSetTimer(1);
   }

   WriteSelfQuote();
   if(InpRole == ROLE_FOLLOWER)
      PrimeLastCommandId();
   SetStatus("Ready", C'90,210,140');
   UpdatePanel();
   ChartRedraw();
   return INIT_SUCCEEDED;
}

void OnDeinit(const int reason)
{
   EventKillTimer();
   ObjectsDeleteAll(0, PFX);
   ChartRedraw();
}

void OnTick()
{
   WriteSelfQuote();
   ReadPeerQuote();
   if(InpRole == ROLE_FOLLOWER)
      CheckCommand();
   if(InpRole == ROLE_SIGNAL)
      ProcessAutoSwitches();
   UpdatePanel();
}

void OnTimer()
{
   WriteSelfQuote();
   ReadPeerQuote();
   if(InpRole == ROLE_FOLLOWER)
      CheckCommand();
   if(InpRole == ROLE_SIGNAL)
      ProcessAutoSwitches();
   UpdatePanel();
}

void OnChartEvent(const int id, const long &lparam, const double &dparam, const string &sparam)
{
   if(id != CHARTEVENT_OBJECT_CLICK || InpRole != ROLE_SIGNAL)
      return;

   if(sparam == PFX + "BTN_BUY")
   {
      g_buySwitch = !g_buySwitch;
      RefreshSwitchButtons();
      SetStatus(g_buySwitch ? "BUY switch ON" : "BUY switch OFF", g_buySwitch ? C'90,210,140' : C'180,180,180');
      ObjectSetInteger(0, sparam, OBJPROP_STATE, false);
      ChartRedraw();
   }
   else if(sparam == PFX + "BTN_SELL")
   {
      g_sellSwitch = !g_sellSwitch;
      RefreshSwitchButtons();
      SetStatus(g_sellSwitch ? "SELL switch ON" : "SELL switch OFF", g_sellSwitch ? C'90,210,140' : C'180,180,180');
      ObjectSetInteger(0, sparam, OBJPROP_STATE, false);
      ChartRedraw();
   }
   else if(sparam == PFX + "BTN_CLOSE_BUY")
   {
      g_closeBuySwitch = !g_closeBuySwitch;
      RefreshSwitchButtons();
      SetStatus(g_closeBuySwitch ? "CLOSE BUY switch ON" : "CLOSE BUY switch OFF", g_closeBuySwitch ? C'255,190,90' : C'180,180,180');
      ObjectSetInteger(0, sparam, OBJPROP_STATE, false);
      ChartRedraw();
   }
   else if(sparam == PFX + "BTN_CLOSE_SELL")
   {
      g_closeSellSwitch = !g_closeSellSwitch;
      RefreshSwitchButtons();
      SetStatus(g_closeSellSwitch ? "CLOSE SELL switch ON" : "CLOSE SELL switch OFF", g_closeSellSwitch ? C'255,190,90' : C'180,180,180');
      ObjectSetInteger(0, sparam, OBJPROP_STATE, false);
      ChartRedraw();
   }
}

void ProcessAutoSwitches()
{
   if(!g_buySwitch && !g_sellSwitch && !g_closeBuySwitch && !g_closeSellSwitch)
      return;
   if(!CanUsePeerQuote())
      return;

   MqlTick tick;
   if(!SymbolInfoTick(_Symbol, tick))
      return;

   double sellLoss = tick.bid - g_peerQuote.ask;
   double buyLoss = g_peerQuote.bid - tick.ask;

   if(g_closeBuySwitch && sellLoss > InpCloseBuySetLoss)
   {
      g_closeBuySwitch = false;
      RefreshSwitchButtons();
      SendCloseBuySell();
      return;
   }

   if(g_closeSellSwitch && buyLoss > InpCloseSellSetLoss)
   {
      g_closeSellSwitch = false;
      RefreshSwitchButtons();
      SendCloseSellBuy();
      return;
   }

   if(g_buySwitch && buyLoss > InpBuySetLoss)
   {
      g_buySwitch = false;
      RefreshSwitchButtons();
      SendAndMaybeTrade("BUY");
      return;
   }

   if(g_sellSwitch && sellLoss > InpSellSetLoss)
   {
      g_sellSwitch = false;
      RefreshSwitchButtons();
      SendAndMaybeTrade("SELL");
      return;
   }
}

void SendCloseBuySell()
{
   SendCloseCommand("CLOSE_BUY_SELL", POSITION_TYPE_BUY);
}

void SendCloseSellBuy()
{
   SendCloseCommand("CLOSE_SELL_BUY", POSITION_TYPE_SELL);
}

void SendCloseAll()
{
   SendCloseCommand("CLOSE_ALL", -1);
}

void SendCloseCommand(const string command, int signalPositionType)
{
   long id = MakeSignalId();
   string line = StringFormat("%lld,%lld,%s,%s,%.10f,%.10f,%.4f,%.4f",
                              id,
                              LocalNowMs(),
                              _Symbol,
                              command,
                              0.0,
                              0.0,
                              0.0,
                              0.0);

   if(!WriteCommandLine(line))
   {
      SetStatus(StringFormat("Close command write failed %d", GetLastError()), clrRed);
      return;
   }

   g_lastSentId = id;
   int closed = 0;
   int failed = 0;
   if(InpSelfCloseOnSignal)
      ClosePositionsByMagic(_Symbol, InpMagicSignal, signalPositionType, closed, failed);

   if(failed == 0)
      SetStatus("Close sent, local closed=" + IntegerToString(closed), C'90,210,140');
   else
      SetStatus("Close sent, local failed=" + IntegerToString(failed), clrOrange);
}

void SendAndMaybeTrade(const string side)
{
   if(!CanUsePeerQuote())
   {
      SetStatus("Peer quote stale, blocked", clrOrange);
      return;
   }

   MqlTick tick;
   if(!SymbolInfoTick(_Symbol, tick))
   {
      SetStatus("No local tick", clrRed);
      return;
   }

   long id = MakeSignalId();
   string line = StringFormat("%lld,%lld,%s,%s,%.10f,%.10f,%.4f,%.4f",
                              id,
                              LocalNowMs(),
                              _Symbol,
                              side,
                              tick.bid,
                              tick.ask,
                              InpSignalLot,
                              InpFollowerLot);

   if(!WriteCommandLine(line))
   {
      SetStatus(StringFormat("Command write failed %d", GetLastError()), clrRed);
      return;
   }
   g_lastSentId = id;

   bool localOk = true;
   if(InpSelfTradeOnSignal)
      localOk = PlaceMarket(_Symbol, side, InpSignalLot, InpMagicSignal, StringFormat("MHC_SIG:%lld", id));

   if(localOk)
      SetStatus("Sent " + side + " id=" + IntegerToString((int)(id % 1000000)), C'90,210,140');
   else
      SetStatus("Sent, local order failed", clrOrange);
}

void CheckCommand()
{
   if(!FileIsExist(g_commandFile, FILE_COMMON))
      return;

   int fh = FileOpen(g_commandFile, FILE_READ | FILE_TXT | FILE_ANSI | FILE_COMMON | FILE_SHARE_READ | FILE_SHARE_WRITE);
   if(fh == INVALID_HANDLE)
      return;

   string line = "";
   while(!FileIsEnding(fh))
   {
      string s = FileReadString(fh);
      if(StringLen(s) > 10)
         line = s;
   }
   FileClose(fh);

   CommandPacket cmd;
   if(!ParseCommand(line, cmd))
      return;
   if(InpBlockDuplicateSignal && cmd.id == g_lastCommandId)
      return;

   long age = LocalNowMs() - cmd.ts_msc;
   if(InpBlockStaleCommand && (age < 0 || age > InpMaxCommandAgeMs))
   {
      g_lastCommandId = cmd.id;
      SetStatus("Ignored stale command", clrOrange);
      return;
   }

   if(cmd.side == "CLOSE_ALL" || cmd.side == "CLOSE_BUY_SELL" || cmd.side == "CLOSE_SELL_BUY")
   {
      int closed = 0;
      int failed = 0;
      int followerType = -1;
      if(cmd.side == "CLOSE_BUY_SELL")
         followerType = POSITION_TYPE_SELL;
      else if(cmd.side == "CLOSE_SELL_BUY")
         followerType = POSITION_TYPE_BUY;
      ClosePositionsByMagic(_Symbol, InpMagicFollower, followerType, closed, failed);
      g_lastCommandId = cmd.id;
      if(failed == 0)
         SetStatus("Closed by signal, count=" + IntegerToString(closed), C'90,210,140');
      else
         SetStatus("Close failed=" + IntegerToString(failed), clrOrange);
      return;
   }

   string followerSide = cmd.side;
   if(InpFollowerHedgeMode)
      followerSide = (cmd.side == "BUY") ? "SELL" : "BUY";

   double lot = InpFollowerUseSignalLot ? cmd.signal_lot : cmd.follower_lot;
   bool ok = PlaceMarket(_Symbol, followerSide, lot, InpMagicFollower, StringFormat("MHC_FOL:%lld", cmd.id));
   g_lastCommandId = cmd.id;

   if(ok)
      SetStatus("Followed " + followerSide + " id=" + IntegerToString((int)(cmd.id % 1000000)), C'90,210,140');
   else
      SetStatus("Follower order failed", clrRed);
}

bool PlaceMarket(const string symbol, const string side, double lot, int magic, const string comment)
{
   if(lot <= 0.0)
   {
      Print("[ManualHedgeCopyEA] Invalid lot: ", lot);
      return false;
   }

   if(!SymbolSelect(symbol, true))
   {
      Print("[ManualHedgeCopyEA] Symbol unavailable: ", symbol);
      return false;
   }

   MqlTick tick;
   if(!SymbolInfoTick(symbol, tick))
   {
      Print("[ManualHedgeCopyEA] No tick: ", symbol);
      return false;
   }

   int digits = (int)SymbolInfoInteger(symbol, SYMBOL_DIGITS);
   double price = (side == "BUY") ? tick.ask : tick.bid;

   MqlTradeRequest req = {};
   MqlTradeResult  res = {};
   req.action       = TRADE_ACTION_DEAL;
   req.symbol       = symbol;
   req.type         = (side == "BUY") ? ORDER_TYPE_BUY : ORDER_TYPE_SELL;
   req.volume       = NormalizeLot(symbol, lot);
   req.price        = NormalizeDouble(price, digits);
   req.deviation    = InpDeviationPoints;
   req.magic        = magic;
   req.comment      = comment;
   req.type_filling = PickMarketFilling(symbol);

   ResetLastError();
   bool sent = OrderSend(req, res);
   if(!sent)
   {
      Print("[ManualHedgeCopyEA] OrderSend failed. err=", GetLastError(),
            " retcode=", res.retcode, " ", res.comment);
      return false;
   }
   if(res.retcode != TRADE_RETCODE_DONE && res.retcode != TRADE_RETCODE_PLACED)
   {
      Print("[ManualHedgeCopyEA] Order rejected. retcode=", res.retcode, " ", res.comment,
            " side=", side, " lot=", req.volume, " price=", req.price);
      return false;
   }

   Print("[ManualHedgeCopyEA] Market ", side, " ok. ticket=", res.order,
         " deal=", res.deal, " lot=", req.volume, " price=", req.price);
   return true;
}

bool WriteCommandLine(const string line)
{
   ResetLastError();
   int fh = FileOpen(g_commandFile, FILE_WRITE | FILE_TXT | FILE_ANSI | FILE_COMMON | FILE_SHARE_READ | FILE_SHARE_WRITE);
   if(fh == INVALID_HANDLE)
      return false;
   FileWriteString(fh, line + "\n");
   FileFlush(fh);
   FileClose(fh);
   return true;
}

void ClosePositionsByMagic(const string symbol, int magic, int positionTypeFilter, int &closed, int &failed)
{
   closed = 0;
   failed = 0;

   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0)
         continue;
      if(!PositionSelectByTicket(ticket))
         continue;
      if(PositionGetString(POSITION_SYMBOL) != symbol)
         continue;
      if((int)PositionGetInteger(POSITION_MAGIC) != magic)
         continue;
      if(positionTypeFilter >= 0 && (int)PositionGetInteger(POSITION_TYPE) != positionTypeFilter)
         continue;

      if(ClosePositionByTicket(ticket))
         closed++;
      else
         failed++;
   }
}

bool ClosePositionByTicket(ulong ticket)
{
   if(!PositionSelectByTicket(ticket))
      return false;

   string symbol = PositionGetString(POSITION_SYMBOL);
   long posType = PositionGetInteger(POSITION_TYPE);
   double volume = PositionGetDouble(POSITION_VOLUME);
   int magic = (int)PositionGetInteger(POSITION_MAGIC);

   MqlTick tick;
   if(!SymbolInfoTick(symbol, tick))
      return false;

   int digits = (int)SymbolInfoInteger(symbol, SYMBOL_DIGITS);
   string closeSide = (posType == POSITION_TYPE_BUY) ? "SELL" : "BUY";
   double price = (closeSide == "BUY") ? tick.ask : tick.bid;

   MqlTradeRequest req = {};
   MqlTradeResult  res = {};
   req.action       = TRADE_ACTION_DEAL;
   req.position     = ticket;
   req.symbol       = symbol;
   req.type         = (closeSide == "BUY") ? ORDER_TYPE_BUY : ORDER_TYPE_SELL;
   req.volume       = NormalizeLot(symbol, volume);
   req.price        = NormalizeDouble(price, digits);
   req.deviation    = InpDeviationPoints;
   req.magic        = magic;
   req.comment      = "MHC_CLOSE";
   req.type_filling = PickMarketFilling(symbol);

   ResetLastError();
   bool sent = OrderSend(req, res);
   if(!sent)
   {
      Print("[ManualHedgeCopyEA] Close failed. ticket=", ticket,
            " err=", GetLastError(), " retcode=", res.retcode, " ", res.comment);
      return false;
   }
   if(res.retcode != TRADE_RETCODE_DONE && res.retcode != TRADE_RETCODE_PLACED)
   {
      Print("[ManualHedgeCopyEA] Close rejected. ticket=", ticket,
            " retcode=", res.retcode, " ", res.comment);
      return false;
   }

   Print("[ManualHedgeCopyEA] Close ok. ticket=", ticket, " deal=", res.deal);
   return true;
}

double NormalizeLot(const string symbol, double lot)
{
   double step = SymbolInfoDouble(symbol, SYMBOL_VOLUME_STEP);
   double minv = SymbolInfoDouble(symbol, SYMBOL_VOLUME_MIN);
   double maxv = SymbolInfoDouble(symbol, SYMBOL_VOLUME_MAX);
   if(step > 0.0)
      lot = MathFloor(lot / step) * step;
   lot = MathMax(minv, MathMin(maxv, lot));
   return NormalizeDouble(lot, 2);
}

ENUM_ORDER_TYPE_FILLING PickMarketFilling(const string symbol)
{
   int modes = (int)SymbolInfoInteger(symbol, SYMBOL_FILLING_MODE);
   if((modes & SYMBOL_FILLING_IOC) != 0)
      return ORDER_FILLING_IOC;
   if((modes & SYMBOL_FILLING_FOK) != 0)
      return ORDER_FILLING_FOK;
   return ORDER_FILLING_RETURN;
}

void WriteSelfQuote()
{
   MqlTick tick;
   if(!SymbolInfoTick(_Symbol, tick))
      return;

   string line = StringFormat("%lld,%s,%.10f,%.10f",
                              LocalNowMs(),
                              _Symbol,
                              tick.bid,
                              tick.ask);
   int fh = FileOpen(g_selfQuoteFile, FILE_WRITE | FILE_TXT | FILE_ANSI | FILE_COMMON | FILE_SHARE_READ | FILE_SHARE_WRITE);
   if(fh == INVALID_HANDLE)
      return;
   FileWriteString(fh, line + "\n");
   FileFlush(fh);
   FileClose(fh);
}

void ReadPeerQuote()
{
   if(!FileIsExist(g_peerQuoteFile, FILE_COMMON))
   {
      g_peerQuote.valid = false;
      return;
   }

   int fh = FileOpen(g_peerQuoteFile, FILE_READ | FILE_TXT | FILE_ANSI | FILE_COMMON | FILE_SHARE_READ | FILE_SHARE_WRITE);
   if(fh == INVALID_HANDLE)
      return;

   string line = "";
   while(!FileIsEnding(fh))
   {
      string s = FileReadString(fh);
      if(StringLen(s) > 8)
         line = s;
   }
   FileClose(fh);

   QuotePacket q;
   if(ParseQuote(line, q))
      g_peerQuote = q;
}

bool ParseQuote(const string line, QuotePacket &q)
{
   string p[];
   int n = StringSplit(line, ',', p);
   if(n < 4)
      return false;
   q.ts_msc = (long)StringToInteger(p[0]);
   q.symbol = p[1];
   q.bid = StringToDouble(p[2]);
   q.ask = StringToDouble(p[3]);
   q.valid = (q.bid > 0.0 && q.ask > 0.0);
   return q.valid;
}

bool ParseCommand(const string line, CommandPacket &cmd)
{
   string p[];
   int n = StringSplit(line, ',', p);
   if(n < 8)
      return false;
   cmd.id = (long)StringToInteger(p[0]);
   cmd.ts_msc = (long)StringToInteger(p[1]);
   cmd.symbol = p[2];
   cmd.side = p[3];
   cmd.signal_bid = StringToDouble(p[4]);
   cmd.signal_ask = StringToDouble(p[5]);
   cmd.signal_lot = StringToDouble(p[6]);
   cmd.follower_lot = StringToDouble(p[7]);
   cmd.valid = (cmd.id > 0 && (cmd.side == "BUY" || cmd.side == "SELL" || cmd.side == "CLOSE_ALL" || cmd.side == "CLOSE_BUY_SELL" || cmd.side == "CLOSE_SELL_BUY"));
   return cmd.valid;
}

bool CanUsePeerQuote()
{
   if(!InpBlockIfPeerQuoteStale)
      return true;
   if(!g_peerQuote.valid)
      return false;

   long age = LocalNowMs() - g_peerQuote.ts_msc;
   return (age >= 0 && age <= InpMaxPeerQuoteAgeMs);
}

long MakeSignalId()
{
   long nowMs = LocalNowMs();
   long id = (long)TimeCurrent() * 1000000 + (nowMs % 1000000);
   if(id <= g_lastSentId)
      id = g_lastSentId + 1;
   return id;
}

long LocalNowMs()
{
   return (long)TimeLocal() * 1000 + (long)(GetMicrosecondCount() % 1000000) / 1000;
}

void PrimeLastCommandId()
{
   if(!FileIsExist(g_commandFile, FILE_COMMON))
      return;

   int fh = FileOpen(g_commandFile, FILE_READ | FILE_TXT | FILE_ANSI | FILE_COMMON | FILE_SHARE_READ | FILE_SHARE_WRITE);
   if(fh == INVALID_HANDLE)
      return;

   string line = "";
   while(!FileIsEnding(fh))
   {
      string s = FileReadString(fh);
      if(StringLen(s) > 10)
         line = s;
   }
   FileClose(fh);

   CommandPacket cmd;
   if(ParseCommand(line, cmd))
      g_lastCommandId = cmd.id;
}

void BuildPanel()
{
   int x = InpPanelX;
   int y = InpPanelY;
   int h = (InpRole == ROLE_SIGNAL) ? 390 : 255;

   ObjRect(PFX+"BG", x, y, PANEL_W, h, C'24,28,35', C'55,65,80');
   ObjLabel(PFX+"TITLE", x+12, y+10, "Manual Hedge Copy EA", 11, clrWhite);
   ObjLabel(PFX+"ROLE", x+12, y+34, "", 9, C'160,190,230');
   ObjLabel(PFX+"LOCAL", x+12, y+60, "", 9, C'220,220,220');
   ObjLabel(PFX+"PEER", x+12, y+84, "", 9, C'220,220,220');
   ObjLabel(PFX+"AGE", x+12, y+108, "", 9, C'180,190,205');
   ObjLabel(PFX+"LOSS_SELL", x+12, y+138, "", 10, C'255,190,120');
   ObjLabel(PFX+"LOSS_BUY", x+12, y+162, "", 10, C'120,210,255');
   ObjLabel(PFX+"SETLOSS_OPEN", x+12, y+188, "", 9, C'200,200,210');
   ObjLabel(PFX+"SETLOSS_CLOSE", x+12, y+212, "", 9, C'200,200,210');
   ObjLabel(PFX+"STATUS", x+12, y+238, "", 9, C'90,210,140');

   if(InpRole == ROLE_SIGNAL)
   {
      ObjButton(PFX+"BTN_BUY", x+12, y+268, 158, 32, "BUY SWITCH OFF", C'70,80,75');
      ObjButton(PFX+"BTN_SELL", x+182, y+268, 158, 32, "SELL SWITCH OFF", C'85,70,70');
      ObjButton(PFX+"BTN_CLOSE_BUY", x+12, y+308, 158, 32, "CLOSE BUY OFF", C'90,90,105');
      ObjButton(PFX+"BTN_CLOSE_SELL", x+182, y+308, 158, 32, "CLOSE SELL OFF", C'90,90,105');
   }
}

void RefreshSwitchButtons()
{
   if(InpRole != ROLE_SIGNAL)
      return;

   if(ObjectFind(0, PFX+"BTN_BUY") >= 0)
   {
      ObjectSetString(0, PFX+"BTN_BUY", OBJPROP_TEXT, g_buySwitch ? "BUY SWITCH ON" : "BUY SWITCH OFF");
      ObjectSetInteger(0, PFX+"BTN_BUY", OBJPROP_BGCOLOR, g_buySwitch ? C'25,140,80' : C'70,80,75');
   }

   if(ObjectFind(0, PFX+"BTN_SELL") >= 0)
   {
      ObjectSetString(0, PFX+"BTN_SELL", OBJPROP_TEXT, g_sellSwitch ? "SELL SWITCH ON" : "SELL SWITCH OFF");
      ObjectSetInteger(0, PFX+"BTN_SELL", OBJPROP_BGCOLOR, g_sellSwitch ? C'165,55,55' : C'85,70,70');
   }

   if(ObjectFind(0, PFX+"BTN_CLOSE_BUY") >= 0)
   {
      ObjectSetString(0, PFX+"BTN_CLOSE_BUY", OBJPROP_TEXT, g_closeBuySwitch ? "CLOSE BUY ON" : "CLOSE BUY OFF");
      ObjectSetInteger(0, PFX+"BTN_CLOSE_BUY", OBJPROP_BGCOLOR, g_closeBuySwitch ? C'190,120,35' : C'90,90,105');
   }

   if(ObjectFind(0, PFX+"BTN_CLOSE_SELL") >= 0)
   {
      ObjectSetString(0, PFX+"BTN_CLOSE_SELL", OBJPROP_TEXT, g_closeSellSwitch ? "CLOSE SELL ON" : "CLOSE SELL OFF");
      ObjectSetInteger(0, PFX+"BTN_CLOSE_SELL", OBJPROP_BGCOLOR, g_closeSellSwitch ? C'190,120,35' : C'90,90,105');
   }
}

void UpdatePanel()
{
   MqlTick tick;
   SymbolInfoTick(_Symbol, tick);
   int digits = (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS);

   string role = (InpRole == ROLE_SIGNAL) ? "SIGNAL side" : "FOLLOWER side";
   ObjSetText(PFX+"ROLE", "Role: " + role + " | channel: " + InpChannel);
   ObjSetText(PFX+"LOCAL", StringFormat("Local %s  Bid %s  Ask %s",
                                        _Symbol,
                                        DoubleToString(tick.bid, digits),
                                        DoubleToString(tick.ask, digits)));

   long age = -1;
   if(g_peerQuote.valid)
      age = LocalNowMs() - g_peerQuote.ts_msc;

   if(g_peerQuote.valid)
      ObjSetText(PFX+"PEER", StringFormat("Peer  %s  Bid %s  Ask %s",
                                          g_peerQuote.symbol,
                                          DoubleToString(g_peerQuote.bid, digits),
                                          DoubleToString(g_peerQuote.ask, digits)));
   else
      ObjSetText(PFX+"PEER", "Peer quote: waiting");

   ObjSetText(PFX+"AGE", (age >= 0) ? StringFormat("Peer quote age: %lld ms", age) : "Peer quote age: --");
   ObjectSetInteger(0, PFX+"AGE", OBJPROP_COLOR,
                    (age >= 0 && age <= InpMaxPeerQuoteAgeMs) ? C'160,210,160' : C'230,170,90');

   double signalBid = (InpRole == ROLE_SIGNAL) ? tick.bid : g_peerQuote.bid;
   double signalAsk = (InpRole == ROLE_SIGNAL) ? tick.ask : g_peerQuote.ask;
   double followerBid = (InpRole == ROLE_SIGNAL) ? g_peerQuote.bid : tick.bid;
   double followerAsk = (InpRole == ROLE_SIGNAL) ? g_peerQuote.ask : tick.ask;

   if(g_peerQuote.valid)
   {
      double sellCost = signalBid - followerAsk;
      double buyCost  = followerBid - signalAsk;
      ObjSetText(PFX+"LOSS_SELL", "Signal SELL loss = signal Bid - follower Ask = " + DoubleToString(sellCost, digits));
      ObjSetText(PFX+"LOSS_BUY",  "Signal BUY  loss = follower Bid - signal Ask = " + DoubleToString(buyCost, digits));
   }
   else
   {
      ObjSetText(PFX+"LOSS_SELL", "Signal SELL loss = --");
      ObjSetText(PFX+"LOSS_BUY",  "Signal BUY  loss = --");
   }

   ObjSetText(PFX+"SETLOSS_OPEN", StringFormat("Open SetLoss  BUY>%s  SELL>%s",
                                               DoubleToString(InpBuySetLoss, digits),
                                               DoubleToString(InpSellSetLoss, digits)));
   ObjSetText(PFX+"SETLOSS_CLOSE", StringFormat("Close SetLoss  BUY>%s  SELL>%s",
                                                DoubleToString(InpCloseBuySetLoss, digits),
                                                DoubleToString(InpCloseSellSetLoss, digits)));
   ObjSetText(PFX+"STATUS", "Status: " + g_status);
   ObjectSetInteger(0, PFX+"STATUS", OBJPROP_COLOR, g_statusColor);
}

void SetStatus(const string text, color clr)
{
   g_status = text;
   g_statusColor = clr;
   Print("[ManualHedgeCopyEA] ", text);
}

void ObjRect(const string name, int x, int y, int w, int h, color bg, color border)
{
   if(ObjectFind(0, name) < 0)
      ObjectCreate(0, name, OBJ_RECTANGLE_LABEL, 0, 0, 0);
   ObjectSetInteger(0, name, OBJPROP_CORNER, CORNER_LEFT_UPPER);
   ObjectSetInteger(0, name, OBJPROP_XDISTANCE, x);
   ObjectSetInteger(0, name, OBJPROP_YDISTANCE, y);
   ObjectSetInteger(0, name, OBJPROP_XSIZE, w);
   ObjectSetInteger(0, name, OBJPROP_YSIZE, h);
   ObjectSetInteger(0, name, OBJPROP_BGCOLOR, bg);
   ObjectSetInteger(0, name, OBJPROP_BORDER_COLOR, border);
   ObjectSetInteger(0, name, OBJPROP_BACK, false);
}

void ObjLabel(const string name, int x, int y, const string text, int size, color clr)
{
   if(ObjectFind(0, name) < 0)
      ObjectCreate(0, name, OBJ_LABEL, 0, 0, 0);
   ObjectSetInteger(0, name, OBJPROP_CORNER, CORNER_LEFT_UPPER);
   ObjectSetInteger(0, name, OBJPROP_XDISTANCE, x);
   ObjectSetInteger(0, name, OBJPROP_YDISTANCE, y);
   ObjectSetInteger(0, name, OBJPROP_FONTSIZE, size);
   ObjectSetInteger(0, name, OBJPROP_COLOR, clr);
   ObjectSetString(0, name, OBJPROP_FONT, "Arial");
   ObjectSetString(0, name, OBJPROP_TEXT, text);
}

void ObjSetText(const string name, const string text)
{
   if(ObjectFind(0, name) >= 0)
      ObjectSetString(0, name, OBJPROP_TEXT, text);
}

void ObjButton(const string name, int x, int y, int w, int h, const string text, color bg)
{
   if(ObjectFind(0, name) < 0)
      ObjectCreate(0, name, OBJ_BUTTON, 0, 0, 0);
   ObjectSetInteger(0, name, OBJPROP_CORNER, CORNER_LEFT_UPPER);
   ObjectSetInteger(0, name, OBJPROP_XDISTANCE, x);
   ObjectSetInteger(0, name, OBJPROP_YDISTANCE, y);
   ObjectSetInteger(0, name, OBJPROP_XSIZE, w);
   ObjectSetInteger(0, name, OBJPROP_YSIZE, h);
   ObjectSetInteger(0, name, OBJPROP_BGCOLOR, bg);
   ObjectSetInteger(0, name, OBJPROP_COLOR, clrWhite);
   ObjectSetInteger(0, name, OBJPROP_FONTSIZE, 9);
   ObjectSetString(0, name, OBJPROP_FONT, "Arial");
   ObjectSetString(0, name, OBJPROP_TEXT, text);
}
