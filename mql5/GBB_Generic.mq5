//+------------------------------------------------------------------+
//| GBB_Generic.mq5 — Multi-entry-mode EA for MT5 verification      |
//| Supports all mega_screener entry types with common trade mgmt    |
//| Entry modes: atr_bracket, asian_range, momentum, fade, ema_cross,|
//|              breakout_range, vol_spike_bracket, null_bracket      |
//+------------------------------------------------------------------+
#property copyright "GoldBigBrain"
#property version   "1.00"
#property strict

#resource "vol_model_6yr.onnx" as uchar VolModelData[]

#include <Trade\Trade.mqh>

//--- Entry mode enum
enum ENUM_ENTRY_MODE
{
   MODE_ATR_BRACKET      = 0,   // ATR Bracket (buy+sell stop at ±offset)
   MODE_ASIAN_RANGE      = 1,   // Asian Range (buy at asian high, sell at asian low)
   MODE_MOMENTUM_LONG    = 2,   // Momentum Long (BuyStop when ret5 > 0)
   MODE_MOMENTUM_SHORT   = 3,   // Momentum Short (SellStop when ret5 < 0)
   MODE_FADE_LONG        = 4,   // Fade Long (BuyStop when RSI14 < 35)
   MODE_FADE_SHORT       = 5,   // Fade Short (SellStop when RSI14 > 65)
   MODE_EMA_CROSS_LONG   = 6,   // EMA Cross Long (BuyStop when EMA8 > EMA21)
   MODE_EMA_CROSS_SHORT  = 7,   // EMA Cross Short (SellStop when EMA8 < EMA21)
   MODE_BREAKOUT_RANGE   = 8,   // Breakout Range (BuyStop at N-bar high, SellStop at N-bar low)
   MODE_VOL_SPIKE_BRACKET= 9,   // Vol Spike Bracket (bracket when vol_ratio > VolSpikeThresh)
   MODE_NULL_BRACKET     = 10   // Null Bracket (unconditional bracket, no filter)
};

//--- Core inputs
input ENUM_ENTRY_MODE EntryMode = MODE_ATR_BRACKET;
input double   RiskPercent      = 0.8;
input double   SL_ATR_Mult      = 1.0;
input double   TP_ATR_Mult      = 3.0;
input double   BracketOffset    = 0.3;    // ATR mult for bracket offset
input int      BracketBars      = 3;      // Bars to keep pending orders alive
input int      MaxTradesPerDay  = 20;
input double   DailyLossCapPct  = 5.0;
input int      SessionStart     = 7;
input int      SessionEnd       = 20;
input int      MagicNumber      = 20260420;
input double   MaxLotSize       = 0.10;

//--- Trade management
input bool     EnableBreakEven  = true;
input double   BE_ATR_Mult      = 0.3;
input bool     EnableTrailing   = true;
input double   Trail_ATR_Mult   = 0.5;
input bool     EnableTimeStop   = true;
input int      MaxHoldBars      = 8;

//--- ONNX vol gate (0 = disabled)
input double   VolThreshold     = 0.0;

//--- Asian range inputs (only used when EntryMode == MODE_ASIAN_RANGE)
input int      AsianStart       = 0;
input int      AsianEnd         = 7;

//--- Breakout range lookback (only used when EntryMode == MODE_BREAKOUT_RANGE)
input int      BreakoutBars     = 20;

//--- Vol spike threshold (only used when EntryMode == MODE_VOL_SPIKE_BRACKET)
input double   VolSpikeThresh   = 2.0;    // vol/vol_ma20 threshold

//--- Fade RSI thresholds
input double   FadeLongRSI      = 35.0;
input double   FadeShortRSI     = 65.0;

//+------------------------------------------------------------------+
//| Globals                                                          |
//+------------------------------------------------------------------+
long hVolModel = INVALID_HANDLE;
bool useONNX = false;
CTrade trade;

int    todayTrades = 0;
double todayPnL = 0.0;
double dayStartBalance = 0.0;
int    lastDay = -1;

bool   bracketActive = false;
int    bracketBarCount = 0;
ulong  pendingBuyTicket = 0;
ulong  pendingSellTicket = 0;

double tradeEntryPrice = 0.0;
double tradeEntryATR   = 0.0;
int    tradeHoldBars   = 0;
bool   breakEvenDone   = false;
double tradeHighWater  = 0.0;
double tradeLowWater   = 1e30;

// Asian range tracking
double asianHigh = 0.0;
double asianLow  = 1e30;

#define NUM_FEATURES 59
float features[NUM_FEATURES];

#define MAX_BARS 600
double buf_close[MAX_BARS];
double buf_high[MAX_BARS];
double buf_low[MAX_BARS];
double buf_open[MAX_BARS];
double buf_volume[MAX_BARS];

//+------------------------------------------------------------------+
int OnInit()
{
   trade.SetExpertMagicNumber(MagicNumber);
   trade.SetDeviationInPoints(30);
   trade.SetTypeFilling(ORDER_FILLING_IOC);

   // Load ONNX only if vol gate is enabled
   useONNX = (VolThreshold > 0.0);
   if(useONNX)
   {
      hVolModel = OnnxCreateFromBuffer(VolModelData, ONNX_DEFAULT);
      if(hVolModel == INVALID_HANDLE)
      { Print("Failed to load ONNX: ", GetLastError()); return INIT_FAILED; }

      long inputShape[]  = {1, NUM_FEATURES};
      long outputShape[] = {1, 2};
      if(!OnnxSetInputShape(hVolModel, 0, inputShape))
      { Print("Input shape fail: ", GetLastError()); return INIT_FAILED; }
      if(!OnnxSetOutputShape(hVolModel, 1, outputShape))
      { Print("Output shape fail: ", GetLastError()); return INIT_FAILED; }
   }

   Print("GBB_Generic init. Mode=", EnumToString(EntryMode),
         " VT=", VolThreshold, " SL=", SL_ATR_Mult, " TP=", TP_ATR_Mult,
         " BE=", BE_ATR_Mult, " Trail=", Trail_ATR_Mult, " MaxHold=", MaxHoldBars);
   return INIT_SUCCEEDED;
}

//+------------------------------------------------------------------+
void OnDeinit(const int reason)
{
   CancelBracket();
   if(hVolModel != INVALID_HANDLE) OnnxRelease(hVolModel);
}

//+------------------------------------------------------------------+
void OnTick()
{
   static datetime lastBarTime = 0;
   datetime currentBarTime = iTime(_Symbol, PERIOD_M5, 0);
   if(currentBarTime == lastBarTime) return;
   lastBarTime = currentBarTime;

   MqlDateTime dt;
   TimeToStruct(TimeCurrent(), dt);

   // Daily reset
   if(dt.day != lastDay)
   {
      lastDay = dt.day;
      todayTrades = 0;
      todayPnL = 0.0;
      dayStartBalance = AccountInfoDouble(ACCOUNT_BALANCE);
      asianHigh = 0.0;
      asianLow  = 1e30;
   }

   // Track Asian session high/low for asian_range mode
   if(EntryMode == MODE_ASIAN_RANGE)
   {
      if(dt.hour >= AsianStart && dt.hour < AsianEnd)
      {
         double barHigh = iHigh(_Symbol, PERIOD_M5, 1);
         double barLow  = iLow(_Symbol, PERIOD_M5, 1);
         if(barHigh > asianHigh) asianHigh = barHigh;
         if(barLow < asianLow)   asianLow  = barLow;
      }
   }

   // Session filter
   if(dt.hour < SessionStart || dt.hour >= SessionEnd)
   { CancelBracket(); return; }

   // Daily limits
   if(todayTrades >= MaxTradesPerDay) return;
   if(todayPnL < -(dayStartBalance * DailyLossCapPct / 100.0)) return;

   // Manage open position
   if(HasOpenPosition())
   {
      CancelBracket();
      ManageOpenTrade();
      return;
   }

   // Reset trade tracking when no position
   tradeHoldBars = 0;
   breakEvenDone = false;
   tradeHighWater = 0.0;
   tradeLowWater = 1e30;

   // Wait for bracket expiry
   if(bracketActive)
   {
      bracketBarCount++;
      if(bracketBarCount > BracketBars) CancelBracket();
      return;
   }

   // Load bars for indicators
   if(!LoadBars()) return;

   // ONNX vol gate (if enabled)
   if(useONNX)
   {
      if(!ComputeFeatures()) return;
      float volProba = RunModel(hVolModel);
      if(volProba < 0) return;
      if(volProba < (float)VolThreshold) return;
   }

   // Dispatch to entry mode
   switch(EntryMode)
   {
      case MODE_ATR_BRACKET:       EntryATRBracket(); break;
      case MODE_ASIAN_RANGE:       EntryAsianRange(); break;
      case MODE_MOMENTUM_LONG:     EntryMomentumLong(); break;
      case MODE_MOMENTUM_SHORT:    EntryMomentumShort(); break;
      case MODE_FADE_LONG:         EntryFadeLong(); break;
      case MODE_FADE_SHORT:        EntryFadeShort(); break;
      case MODE_EMA_CROSS_LONG:    EntryEmaCrossLong(); break;
      case MODE_EMA_CROSS_SHORT:   EntryEmaCrossShort(); break;
      case MODE_BREAKOUT_RANGE:    EntryBreakoutRange(); break;
      case MODE_VOL_SPIKE_BRACKET: EntryVolSpikeBracket(); break;
      case MODE_NULL_BRACKET:      EntryNullBracket(); break;
   }
}

//+------------------------------------------------------------------+
//| ENTRY MODE IMPLEMENTATIONS                                       |
//+------------------------------------------------------------------+

// Mode 0: ATR bracket — BuyStop + SellStop at ±BracketOffset*ATR from close
void EntryATRBracket()
{
   double atr14 = ComputeATR_AtBar(14, 1);
   if(atr14 < _Point) return;

   double prevClose = buf_close[1];
   double offset = atr14 * BracketOffset;
   double buyLevel  = prevClose + offset;
   double sellLevel = prevClose - offset;

   PlaceBracket(buyLevel, sellLevel, atr14);
}

// Mode 1: Asian range breakout — BuyStop at Asian high, SellStop at Asian low
void EntryAsianRange()
{
   if(asianHigh <= 0.0 || asianLow >= 1e30 || asianHigh <= asianLow) return;

   double atr14 = ComputeATR_AtBar(14, 1);
   if(atr14 < _Point) return;

   double currentAsk = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   double currentBid = SymbolInfoDouble(_Symbol, SYMBOL_BID);

   // Only place if price is between asian levels
   if(asianHigh <= currentAsk || asianLow >= currentBid) return;

   PlaceBracket(asianHigh, asianLow, atr14);
}

// Mode 2: Momentum long — BuyStop only when close > close[5]
void EntryMomentumLong()
{
   double atr14 = ComputeATR_AtBar(14, 1);
   if(atr14 < _Point) return;

   double ret5 = buf_close[1] - buf_close[6];  // close vs close 5 bars ago
   if(ret5 <= 0) return;

   double prevClose = buf_close[1];
   double offset = atr14 * BracketOffset;
   double buyLevel = prevClose + offset;

   PlaceSingle(buyLevel, atr14, true);
}

// Mode 3: Momentum short — SellStop only when close < close[5]
void EntryMomentumShort()
{
   double atr14 = ComputeATR_AtBar(14, 1);
   if(atr14 < _Point) return;

   double ret5 = buf_close[1] - buf_close[6];
   if(ret5 >= 0) return;

   double prevClose = buf_close[1];
   double offset = atr14 * BracketOffset;
   double sellLevel = prevClose - offset;

   PlaceSingle(sellLevel, atr14, false);
}

// Mode 4: Fade long — BuyStop when RSI(14) < FadeLongRSI (oversold)
void EntryFadeLong()
{
   double atr14 = ComputeATR_AtBar(14, 1);
   if(atr14 < _Point) return;

   double rsi14 = ComputeRSI100_AtBar(14, 1);
   if(rsi14 >= FadeLongRSI) return;

   double prevClose = buf_close[1];
   double offset = atr14 * BracketOffset;
   double buyLevel = prevClose + offset;

   PlaceSingle(buyLevel, atr14, true);
}

// Mode 5: Fade short — SellStop when RSI(14) > FadeShortRSI (overbought)
void EntryFadeShort()
{
   double atr14 = ComputeATR_AtBar(14, 1);
   if(atr14 < _Point) return;

   double rsi14 = ComputeRSI100_AtBar(14, 1);
   if(rsi14 <= FadeShortRSI) return;

   double prevClose = buf_close[1];
   double offset = atr14 * BracketOffset;
   double sellLevel = prevClose - offset;

   PlaceSingle(sellLevel, atr14, false);
}

// Mode 6: EMA cross long — BuyStop when EMA(8) > EMA(21)
void EntryEmaCrossLong()
{
   double atr14 = ComputeATR_AtBar(14, 1);
   if(atr14 < _Point) return;

   double ema8  = ComputeEMA_AtBar(buf_close, 8, 1);
   double ema21 = ComputeEMA_AtBar(buf_close, 21, 1);
   if(ema8 <= ema21) return;

   double prevClose = buf_close[1];
   double offset = atr14 * BracketOffset;
   double buyLevel = prevClose + offset;

   PlaceSingle(buyLevel, atr14, true);
}

// Mode 7: EMA cross short — SellStop when EMA(8) < EMA(21)
void EntryEmaCrossShort()
{
   double atr14 = ComputeATR_AtBar(14, 1);
   if(atr14 < _Point) return;

   double ema8  = ComputeEMA_AtBar(buf_close, 8, 1);
   double ema21 = ComputeEMA_AtBar(buf_close, 21, 1);
   if(ema8 >= ema21) return;

   double prevClose = buf_close[1];
   double offset = atr14 * BracketOffset;
   double sellLevel = prevClose - offset;

   PlaceSingle(sellLevel, atr14, false);
}

// Mode 8: Breakout range — BuyStop at N-bar high, SellStop at N-bar low
void EntryBreakoutRange()
{
   double atr14 = ComputeATR_AtBar(14, 1);
   if(atr14 < _Point) return;

   // Find N-bar high/low (completed bars only, start from bar 1)
   double rangeHigh = -1e30;
   double rangeLow  = 1e30;
   for(int i = 1; i <= BreakoutBars; i++)
   {
      if(buf_high[i] > rangeHigh) rangeHigh = buf_high[i];
      if(buf_low[i] < rangeLow)   rangeLow  = buf_low[i];
   }

   double currentAsk = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   double currentBid = SymbolInfoDouble(_Symbol, SYMBOL_BID);

   // Only if price is inside the range
   if(rangeHigh <= currentAsk || rangeLow >= currentBid) return;

   PlaceBracket(rangeHigh, rangeLow, atr14);
}

// Mode 9: Vol spike bracket — bracket when volume ratio > threshold
void EntryVolSpikeBracket()
{
   double atr14 = ComputeATR_AtBar(14, 1);
   if(atr14 < _Point) return;

   // Compute vol/vol_ma20
   double vol = buf_volume[1];
   double vol_ma20 = 0;
   for(int i = 1; i <= 20; i++) vol_ma20 += buf_volume[i];
   vol_ma20 /= 20.0;

   double volRatio = (vol_ma20 > 0) ? vol / vol_ma20 : 0.0;
   if(volRatio < VolSpikeThresh) return;

   double prevClose = buf_close[1];
   double offset = atr14 * BracketOffset;
   double buyLevel  = prevClose + offset;
   double sellLevel = prevClose - offset;

   PlaceBracket(buyLevel, sellLevel, atr14);
}

// Mode 10: Null bracket — unconditional bracket, no entry filter
void EntryNullBracket()
{
   double atr14 = ComputeATR_AtBar(14, 1);
   if(atr14 < _Point) return;

   double prevClose = buf_close[1];
   double offset = atr14 * BracketOffset;
   double buyLevel  = prevClose + offset;
   double sellLevel = prevClose - offset;

   PlaceBracket(buyLevel, sellLevel, atr14);
}

//+------------------------------------------------------------------+
//| ORDER PLACEMENT HELPERS                                          |
//+------------------------------------------------------------------+

// Place a bracket: BuyStop + SellStop
void PlaceBracket(double buyLevel, double sellLevel, double atr14)
{
   double sl_pts = atr14 * SL_ATR_Mult;
   double tp_pts = atr14 * TP_ATR_Mult;
   double lotSize = CalcLotSize(sl_pts);

   int digits = (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS);
   buyLevel  = NormalizeDouble(buyLevel, digits);
   sellLevel = NormalizeDouble(sellLevel, digits);
   double buySL  = NormalizeDouble(buyLevel - sl_pts, digits);
   double buyTP  = NormalizeDouble(buyLevel + tp_pts, digits);
   double sellSL = NormalizeDouble(sellLevel + sl_pts, digits);
   double sellTP = NormalizeDouble(sellLevel - tp_pts, digits);

   string comment = StringFormat("G%d", (int)EntryMode);

   if(trade.BuyStop(lotSize, buyLevel, _Symbol, buySL, buyTP,
                     ORDER_TIME_GTC, 0, comment))
      pendingBuyTicket = trade.ResultOrder();
   else { Print("BuyStop fail: ", trade.ResultRetcodeDescription()); return; }

   if(trade.SellStop(lotSize, sellLevel, _Symbol, sellSL, sellTP,
                      ORDER_TIME_GTC, 0, comment))
      pendingSellTicket = trade.ResultOrder();
   else
   {
      Print("SellStop fail: ", trade.ResultRetcodeDescription());
      trade.OrderDelete(pendingBuyTicket); pendingBuyTicket = 0;
      return;
   }

   bracketActive = true;
   bracketBarCount = 0;
}

// Place a single pending order (BuyStop or SellStop)
void PlaceSingle(double level, double atr14, bool isBuy)
{
   double sl_pts = atr14 * SL_ATR_Mult;
   double tp_pts = atr14 * TP_ATR_Mult;
   double lotSize = CalcLotSize(sl_pts);

   int digits = (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS);
   level = NormalizeDouble(level, digits);

   string comment = StringFormat("G%d", (int)EntryMode);

   if(isBuy)
   {
      double sl = NormalizeDouble(level - sl_pts, digits);
      double tp = NormalizeDouble(level + tp_pts, digits);
      if(trade.BuyStop(lotSize, level, _Symbol, sl, tp, ORDER_TIME_GTC, 0, comment))
         pendingBuyTicket = trade.ResultOrder();
      else { Print("BuyStop fail: ", trade.ResultRetcodeDescription()); return; }
   }
   else
   {
      double sl = NormalizeDouble(level + sl_pts, digits);
      double tp = NormalizeDouble(level - tp_pts, digits);
      if(trade.SellStop(lotSize, level, _Symbol, sl, tp, ORDER_TIME_GTC, 0, comment))
         pendingSellTicket = trade.ResultOrder();
      else { Print("SellStop fail: ", trade.ResultRetcodeDescription()); return; }
   }

   bracketActive = true;
   bracketBarCount = 0;
}

// Calculate lot size from risk and SL distance
double CalcLotSize(double sl_pts)
{
   double riskUsd   = AccountInfoDouble(ACCOUNT_BALANCE) * RiskPercent / 100.0;
   double tickValue = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE);
   double tickSize  = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);
   double lotStep   = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);
   double minLot    = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
   double slTicks   = sl_pts / tickSize;
   double lotSize   = riskUsd / (slTicks * tickValue);
   lotSize = MathFloor(lotSize / lotStep) * lotStep;
   lotSize = MathMax(lotSize, minLot);
   lotSize = MathMin(lotSize, MaxLotSize);
   return lotSize;
}

//+------------------------------------------------------------------+
//| POSITION MANAGEMENT                                              |
//+------------------------------------------------------------------+

bool HasOpenPosition()
{
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      if(PositionGetTicket(i) > 0)
      {
         if(PositionGetInteger(POSITION_MAGIC) == MagicNumber &&
            PositionGetString(POSITION_SYMBOL) == _Symbol)
            return true;
      }
   }
   return false;
}

void SelectMyPosition()
{
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      if(PositionGetTicket(i) > 0)
      {
         if(PositionGetInteger(POSITION_MAGIC) == MagicNumber &&
            PositionGetString(POSITION_SYMBOL) == _Symbol)
            return;
      }
   }
}

void CancelBracket()
{
   if(pendingBuyTicket > 0)  { trade.OrderDelete(pendingBuyTicket);  pendingBuyTicket = 0; }
   if(pendingSellTicket > 0) { trade.OrderDelete(pendingSellTicket); pendingSellTicket = 0; }
   bracketActive = false;
   bracketBarCount = 0;
}

void ManageOpenTrade()
{
   SelectMyPosition();

   long posType = PositionGetInteger(POSITION_TYPE);
   double posSL = PositionGetDouble(POSITION_SL);
   double posTP = PositionGetDouble(POSITION_TP);
   double openPrice = PositionGetDouble(POSITION_PRICE_OPEN);
   double currentPrice = PositionGetDouble(POSITION_PRICE_CURRENT);
   ulong posTicket = PositionGetInteger(POSITION_TICKET);
   int digits = (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS);
   double spread = SymbolInfoInteger(_Symbol, SYMBOL_SPREAD) * _Point;

   if(tradeEntryPrice == 0.0)
   {
      tradeEntryPrice = openPrice;
      tradeEntryATR = ComputeATR_AtBar(14, 1);
   }

   tradeHoldBars++;

   // Time stop: close losing trades after MaxHoldBars
   if(EnableTimeStop && tradeHoldBars >= MaxHoldBars)
   {
      double posProfit = PositionGetDouble(POSITION_PROFIT);
      if(posProfit < 0)
      {
         trade.PositionClose(posTicket);
         return;
      }
   }

   // Track favorable move and watermarks
   double favMove = 0;
   if(posType == POSITION_TYPE_BUY)
   {
      favMove = currentPrice - openPrice;
      if(currentPrice > tradeHighWater) tradeHighWater = currentPrice;
   }
   else
   {
      favMove = openPrice - currentPrice;
      if(currentPrice < tradeLowWater) tradeLowWater = currentPrice;
   }

   // Break-even
   double beThresh = tradeEntryATR * BE_ATR_Mult;
   if(EnableBreakEven && !breakEvenDone && favMove >= beThresh)
   {
      double newSL;
      if(posType == POSITION_TYPE_BUY)
         newSL = NormalizeDouble(openPrice + spread, digits);
      else
         newSL = NormalizeDouble(openPrice - spread, digits);

      if((posType == POSITION_TYPE_BUY && newSL > posSL) ||
         (posType == POSITION_TYPE_SELL && newSL < posSL))
      {
         trade.PositionModify(posTicket, newSL, posTP);
         breakEvenDone = true;
         posSL = newSL;
      }
   }

   // Trailing stop (only after break-even)
   if(EnableTrailing && breakEvenDone)
   {
      double trailDist = tradeEntryATR * Trail_ATR_Mult;
      double newSL;
      if(posType == POSITION_TYPE_BUY)
      {
         newSL = NormalizeDouble(tradeHighWater - trailDist, digits);
         if(newSL > posSL)
            trade.PositionModify(posTicket, newSL, posTP);
      }
      else
      {
         newSL = NormalizeDouble(tradeLowWater + trailDist, digits);
         if(newSL < posSL)
            trade.PositionModify(posTicket, newSL, posTP);
      }
   }
}

//+------------------------------------------------------------------+
//| TRADE TRANSACTION HANDLER                                        |
//+------------------------------------------------------------------+
void OnTradeTransaction(const MqlTradeTransaction& trans,
                        const MqlTradeRequest& request,
                        const MqlTradeResult& result)
{
   if(trans.type == TRADE_TRANSACTION_DEAL_ADD && trans.deal != 0)
   {
      if(HistoryDealSelect(trans.deal))
      {
         if(HistoryDealGetInteger(trans.deal, DEAL_MAGIC) != MagicNumber) return;
         todayPnL += HistoryDealGetDouble(trans.deal, DEAL_PROFIT)
                   + HistoryDealGetDouble(trans.deal, DEAL_COMMISSION)
                   + HistoryDealGetDouble(trans.deal, DEAL_SWAP);

         if(HistoryDealGetInteger(trans.deal, DEAL_ENTRY) == DEAL_ENTRY_IN && bracketActive)
         {
            long dealType = HistoryDealGetInteger(trans.deal, DEAL_TYPE);
            if(dealType == DEAL_TYPE_BUY && pendingSellTicket > 0)
            { trade.OrderDelete(pendingSellTicket); pendingSellTicket = 0; }
            else if(dealType == DEAL_TYPE_SELL && pendingBuyTicket > 0)
            { trade.OrderDelete(pendingBuyTicket); pendingBuyTicket = 0; }
            pendingBuyTicket = 0;
            pendingSellTicket = 0;
            bracketActive = false;
            todayTrades++;

            tradeEntryPrice = HistoryDealGetDouble(trans.deal, DEAL_PRICE);
            tradeEntryATR = ComputeATR_AtBar(14, 1);
            tradeHoldBars = 0;
            breakEvenDone = false;
            tradeHighWater = tradeEntryPrice;
            tradeLowWater = tradeEntryPrice;
         }
      }
   }
}

//+------------------------------------------------------------------+
//| DATA LOADING                                                     |
//+------------------------------------------------------------------+
bool LoadBars()
{
   MqlRates rates[];
   int copied = CopyRates(_Symbol, PERIOD_M5, 0, MAX_BARS, rates);
   if(copied < MAX_BARS) return false;
   for(int i = 0; i < MAX_BARS; i++)
   {
      int j = MAX_BARS - 1 - i;
      buf_close[i]  = rates[j].close;
      buf_high[i]   = rates[j].high;
      buf_low[i]    = rates[j].low;
      buf_open[i]   = rates[j].open;
      buf_volume[i] = (double)rates[j].tick_volume;
   }
   return true;
}

//+------------------------------------------------------------------+
//| INDICATOR HELPERS                                                 |
//+------------------------------------------------------------------+
double SafeDiv(double a, double b)
{ return MathAbs(b) < 1e-10 ? 0.0 : a / b; }

double Clamp(double v, double lo, double hi)
{ return v < lo ? lo : (v > hi ? hi : v); }

double ComputeATR_AtBar(int period, int at_bar)
{
   int seed_start = MAX_BARS - 2;
   int seed_end   = MAX_BARS - 1 - period;
   double atr = 0;
   for(int i = seed_start; i > seed_end; i--)
   {
      double tr = MathMax(buf_high[i] - buf_low[i],
                  MathMax(MathAbs(buf_high[i] - buf_close[i+1]),
                          MathAbs(buf_low[i]  - buf_close[i+1])));
      atr += tr;
   }
   atr /= period;
   for(int i = seed_end; i >= at_bar; i--)
   {
      double tr = MathMax(buf_high[i] - buf_low[i],
                  MathMax(MathAbs(buf_high[i] - buf_close[i+1]),
                          MathAbs(buf_low[i]  - buf_close[i+1])));
      atr = atr * (period - 1.0) / period + tr / period;
   }
   return atr;
}

double ComputeEMA_AtBar(const double &arr[], int span, int at_bar)
{
   double mult = 2.0 / (span + 1.0);
   double ema_val = arr[MAX_BARS - 1];
   for(int i = MAX_BARS - 2; i >= at_bar; i--)
      ema_val = arr[i] * mult + ema_val * (1.0 - mult);
   return ema_val;
}

double ComputeRSI100_AtBar(int period, int at_bar)
{
   double avgGain = 0, avgLoss = 0;
   int seed_start = MAX_BARS - 2;
   int seed_end   = MAX_BARS - 1 - period;
   for(int i = seed_start; i > seed_end; i--)
   {
      double diff = buf_close[i] - buf_close[i+1];
      if(diff > 0) avgGain += diff; else avgLoss -= diff;
   }
   avgGain /= period;
   avgLoss /= period;
   for(int i = seed_end; i >= at_bar; i--)
   {
      double diff = buf_close[i] - buf_close[i+1];
      double gain = diff > 0 ? diff : 0.0;
      double loss = diff < 0 ? -diff : 0.0;
      avgGain = (avgGain * (period - 1.0) + gain) / period;
      avgLoss = (avgLoss * (period - 1.0) + loss) / period;
   }
   if(MathAbs(avgGain + avgLoss) < 1e-10) return 50.0;
   double rs = SafeDiv(avgGain, avgLoss);
   return 100.0 - 100.0 / (1.0 + rs);
}

double ComputeEMA_OnArray(const double &arr[], int arrSize, int span, int at_bar)
{
   double mult = 2.0 / (span + 1.0);
   double ema_val = arr[arrSize - 1];
   for(int i = arrSize - 2; i >= at_bar; i--)
      ema_val = arr[i] * mult + ema_val * (1.0 - mult);
   return ema_val;
}

//+------------------------------------------------------------------+
//| ONNX FEATURE COMPUTATION (exact match to BracketV5)              |
//+------------------------------------------------------------------+
bool ComputeFeatures()
{
   int sb = 1;
   double c  = buf_close[sb], hi = buf_high[sb], lo = buf_low[sb];
   double op = buf_open[sb], vol = buf_volume[sb];
   double rng = hi - lo;

   double atr14 = ComputeATR_AtBar(14, sb);
   double atr50 = ComputeATR_AtBar(50, sb);
   double atr14_prev = ComputeATR_AtBar(14, sb + 1);

   double ema8  = ComputeEMA_AtBar(buf_close, 8, sb);
   double ema21 = ComputeEMA_AtBar(buf_close, 21, sb);
   double ema50 = ComputeEMA_AtBar(buf_close, 50, sb);
   double ema200 = ComputeEMA_AtBar(buf_close, 200, sb);

   features[0] = (float)Clamp(SafeDiv(atr14, c), -10, 10);
   features[1] = (float)Clamp(SafeDiv(atr14, atr50), -10, 10);
   features[2] = (float)Clamp(SafeDiv(atr14_prev, buf_close[sb + 1]), -10, 10);
   features[3] = (float)Clamp(SafeDiv(ema8 - ema21, atr14), -10, 10);
   features[4] = (float)Clamp(SafeDiv(c - ema50, atr14), -10, 10);
   features[5] = (float)Clamp(SafeDiv(c - ema200, atr14), -10, 10);
   features[6] = ema8 > ema21 ? 1.0f : 0.0f;
   features[7] = c > ema50 ? 1.0f : 0.0f;
   features[8] = c > ema200 ? 1.0f : 0.0f;

   double rsi14_val = ComputeRSI100_AtBar(14, sb);
   features[9] = (float)Clamp(rsi14_val, -10, 10);
   features[10] = (float)Clamp(ComputeRSI100_AtBar(14, sb + 1), -10, 10);
   features[11] = (float)Clamp(ComputeRSI100_AtBar(14, sb + 2), -10, 10);
   features[12] = rsi14_val > 70.0 ? 1.0f : 0.0f;
   features[13] = rsi14_val < 30.0 ? 1.0f : 0.0f;
   features[14] = (float)Clamp(ComputeRSI100_AtBar(7, sb), -10, 10);

   double sma20 = 0;
   for(int i = sb; i < sb + 20; i++) sma20 += buf_close[i];
   sma20 /= 20.0;
   double var20 = 0;
   for(int i = sb; i < sb + 20; i++) { double d = buf_close[i] - sma20; var20 += d * d; }
   double bb_std = MathSqrt(var20 / 19.0);
   double bb_upper = sma20 + 2.0 * bb_std;
   double bb_lower = sma20 - 2.0 * bb_std;
   features[15] = (float)Clamp(SafeDiv(c - bb_lower, bb_upper - bb_lower), -10, 10);

   double sma20_prev = 0;
   for(int i = sb + 1; i < sb + 21; i++) sma20_prev += buf_close[i];
   sma20_prev /= 20.0;
   double var20_prev = 0;
   for(int i = sb + 1; i < sb + 21; i++) { double d = buf_close[i] - sma20_prev; var20_prev += d * d; }
   double bb_std_prev = MathSqrt(var20_prev / 19.0);
   double bb_upper_prev = sma20_prev + 2.0 * bb_std_prev;
   double bb_lower_prev = sma20_prev - 2.0 * bb_std_prev;
   features[16] = (float)Clamp(SafeDiv(buf_close[sb + 1] - bb_lower_prev, bb_upper_prev - bb_lower_prev), -10, 10);
   features[17] = (float)Clamp(SafeDiv(bb_upper - bb_lower, sma20), -10, 10);

   double macd_arr[MAX_BARS];
   for(int i = 0; i < MAX_BARS; i++)
   {
      double e12 = ComputeEMA_AtBar(buf_close, 12, i);
      double e26 = ComputeEMA_AtBar(buf_close, 26, i);
      macd_arr[i] = e12 - e26;
   }
   double macd_signal = ComputeEMA_OnArray(macd_arr, MAX_BARS, 9, sb);
   features[18] = (float)Clamp(SafeDiv(macd_arr[sb] - macd_signal, atr14), -10, 10);
   double macd_signal_prev = ComputeEMA_OnArray(macd_arr, MAX_BARS, 9, sb + 1);
   features[19] = (float)Clamp(SafeDiv(macd_arr[sb + 1] - macd_signal_prev, atr14_prev), -10, 10);

   double vol_ma20 = 0;
   for(int i = sb; i < sb + 20; i++) vol_ma20 += buf_volume[i];
   vol_ma20 /= 20.0;
   features[20] = (float)Clamp(SafeDiv(vol, vol_ma20), -10, 10);
   features[21] = (float)Clamp(SafeDiv(rng, atr14), -10, 10);
   features[22] = (float)Clamp(SafeDiv(MathAbs(c - op), rng), -10, 10);

   double rng_prev = buf_high[sb + 1] - buf_low[sb + 1];
   features[23] = (float)Clamp(SafeDiv(MathAbs(buf_close[sb + 1] - buf_open[sb + 1]), rng_prev), -10, 10);
   features[24] = (float)Clamp(SafeDiv(hi - MathMax(op, c), rng), -10, 10);
   features[25] = (float)Clamp(SafeDiv(MathMin(op, c) - lo, rng), -10, 10);
   features[26] = (float)Clamp(SafeDiv(c - lo, rng), -10, 10);
   features[27] = c > op ? 1.0f : 0.0f;
   features[28] = (float)Clamp(SafeDiv(c - buf_close[sb + 1], atr14), -10, 10);
   features[29] = (float)Clamp(SafeDiv(buf_close[sb + 1] - buf_close[sb + 2], atr14_prev), -10, 10);

   double atr14_prev2 = ComputeATR_AtBar(14, sb + 2);
   features[30] = (float)Clamp(SafeDiv(buf_close[sb + 2] - buf_close[sb + 3], atr14_prev2), -10, 10);
   features[31] = (float)Clamp(SafeDiv(c - buf_close[sb + 5], atr14), -10, 10);
   features[32] = (float)Clamp(SafeDiv(c - buf_close[sb + 10], atr14), -10, 10);
   features[33] = (float)Clamp(SafeDiv(c - buf_close[sb + 20], atr14), -10, 10);
   features[34] = (lo < buf_high[sb + 1] && hi > buf_low[sb + 1]) ? 1.0f : 0.0f;

   MqlDateTime mdt;
   TimeToStruct(iTime(_Symbol, PERIOD_M5, 1), mdt);
   double hour_val = (double)mdt.hour;
   double min_val  = (double)mdt.min;

   features[35] = (float)Clamp(hour_val, -10, 10);
   features[36] = (float)Clamp(min_val, -10, 10);
   int py_dow = (mdt.day_of_week + 6) % 7;
   features[37] = (float)Clamp((double)py_dow, -10, 10);
   features[38] = (hour_val >= 7.0 && hour_val < 16.0) ? 1.0f : 0.0f;
   features[39] = (hour_val >= 13.0 && hour_val < 22.0) ? 1.0f : 0.0f;
   features[40] = (hour_val >= 0.0 && hour_val < 7.0) ? 1.0f : 0.0f;

   double mod50 = MathMod(c, 50.0);
   features[41] = (float)Clamp(MathMin(mod50, 50.0 - mod50) / 50.0, -10, 10);
   double mod100 = MathMod(c, 100.0);
   features[42] = (float)Clamp(MathMin(mod100, 100.0 - mod100) / 100.0, -10, 10);

   int lookback = 10;
   int last_sh_idx = MAX_BARS - 1;
   int last_sl_idx = MAX_BARS - 1;
   for(int i = MAX_BARS - 1 - lookback; i >= sb; i--)
   {
      double max_h = -1e30;
      double min_l = 1e30;
      for(int j = i; j <= i + lookback; j++)
      {
         if(buf_high[j] > max_h) max_h = buf_high[j];
         if(buf_low[j] < min_l) min_l = buf_low[j];
      }
      if(buf_high[i + lookback] == max_h) last_sh_idx = i + lookback;
      if(buf_low[i + lookback] == min_l) last_sl_idx = i + lookback;
   }
   features[43] = (float)Clamp((double)(last_sh_idx - sb), -10, 10);
   features[44] = (float)Clamp((double)(last_sl_idx - sb), -10, 10);

   features[45] = (float)MathSin(2.0 * M_PI * hour_val / 24.0);
   features[46] = (float)MathCos(2.0 * M_PI * hour_val / 24.0);

   features[47] = (float)Clamp(MathMod(hour_val - 7.0 + 24.0, 24.0), -10, 10);
   features[48] = (float)Clamp(MathMod(hour_val - 13.0 + 24.0, 24.0), -10, 10);

   double h1_max = -1e30, h1_min = 1e30;
   for(int i = sb; i < sb + 12; i++)
   {
      if(buf_high[i] > h1_max) h1_max = buf_high[i];
      if(buf_low[i] < h1_min) h1_min = buf_low[i];
   }
   features[49] = (float)Clamp(SafeDiv(h1_max - h1_min, atr14), -10, 10);

   double h4_max = -1e30, h4_min = 1e30;
   for(int i = sb; i < sb + 48; i++)
   {
      if(buf_high[i] > h4_max) h4_max = buf_high[i];
      if(buf_low[i] < h4_min) h4_min = buf_low[i];
   }
   features[50] = (float)Clamp(SafeDiv(h4_max - h4_min, atr14), -10, 10);

   features[51] = (float)Clamp(ComputeRSI100_AtBar(14, sb), -10, 10);
   features[52] = (float)Clamp(ComputeRSI100_AtBar(14, sb), -10, 10);

   double ema20 = ComputeEMA_AtBar(buf_close, 20, sb);
   features[53] = (float)Clamp(SafeDiv(c - ema20, atr14), -10, 10);
   features[54] = (float)Clamp(SafeDiv(c - ema20, atr14), -10, 10);

   int hh_count = 0;
   for(int i = sb; i < sb + 10; i++)
      if(buf_high[i] > buf_high[i + 1]) hh_count++;
   features[55] = (float)Clamp(hh_count / 10.0, -10, 10);

   int ll_count = 0;
   for(int i = sb; i < sb + 10; i++)
      if(buf_low[i] < buf_low[i + 1]) ll_count++;
   features[56] = (float)Clamp(ll_count / 10.0, -10, 10);

   double past10_range = 0;
   for(int i = sb; i < sb + 10; i++) past10_range += buf_high[i] - buf_low[i];
   past10_range /= 10.0;
   features[57] = (float)Clamp(SafeDiv(rng, past10_range), -10, 10);

   double path_sum = 0;
   for(int i = sb; i < sb + 10; i++)
      path_sum += MathAbs(buf_close[i] - buf_close[i + 1]);
   features[58] = (float)Clamp(SafeDiv(MathAbs(c - buf_close[sb + 10]), path_sum), -10, 10);

   return true;
}

//+------------------------------------------------------------------+
float RunModel(long handle)
{
   float input_data[];
   ArrayResize(input_data, NUM_FEATURES);
   for(int i = 0; i < NUM_FEATURES; i++) input_data[i] = features[i];

   long labels[];
   float probas[];
   ArrayResize(labels, 1);
   ArrayResize(probas, 2);

   if(!OnnxRun(handle, ONNX_NO_CONVERSION, input_data, labels, probas))
   { Print("OnnxRun failed: ", GetLastError()); return -1.0; }

   return probas[1];
}
//+------------------------------------------------------------------+
