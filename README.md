ManualHedgeCopyEA for MT5
ManualHedgeCopyEA is a specialized MetaTrader 5 Expert Advisor (EA) designed for high-speed,cross-terminal manual market hedge copying.
It utilizes millisecond polling and local file-based Inter-Process Communication (IPC) to synchronize trades between a "Signal" terminal and a "Follower" terminal.
This system is built for environments where low latency is critical, 
employing a hybrid approach that calculates real-time arbitrage/hedge costs while allowing execution via dedicated UI switches.
Core Features
-Millisecond Polling: Achieves near-instant state synchronization using MT5's millisecond timer (default 10ms).
-Zero-Network IPC: Communicates entirely through the MT5 Common/Files directory using fast CSV read/writes, eliminating network overhead.
-Hedge Mode: Automatically reverses positions on the follower terminal (e.g., a Signal BUY becomes a Follower SELL).  
-Real-time Cost Calculation: Continuously calculates and displays the exact cost of entering a hedged position across both terminals.
-Auto Loss Execution: Trigger trades automatically when the calculated loss exceeds pre-defined set-loss thresholds.
-Risk Guards: Built-in circuit breakers block trades if peer quotes are stale (e.g., >500ms old) or if duplicate/stale commands are detected.
Architecture & Logic
The EA relies on two primary formulas to determine the real-time cost (loss) of entering a fully hedged position across two different brokers/feeds.
Signal SELL Hedge Entry Cost:$\text{Loss}_{Sell} = \text{Bid}_{Signal} - \text{Ask}_{Follower}$
Signal BUY Hedge Entry Cost:$\text{Loss}_{Buy} = \text{Bid}_{Follower} - \text{Ask}_{Signal}$
The Signal terminal broadcasts its local quotes and commands, while the Follower terminal continuously reads these quotes to maintain synchronization.
Installation & Setup
Environment: Ensure both MT5 terminals are running on the exact same VPS or Windows user account.
Shared Directory: Both terminals must have access to the same MT5 common files folder (Terminal\Common\Files).  
Deployment: Attach ManualHedgeCopyEA.mq5 to a chart on both terminals.
Role Assignment: * On the first terminal, set InpRole to ROLE_SIGNAL.
On the second terminal, set InpRole to ROLE_FOLLOWER.
Channel Matching: Ensure InpChannel (default: manual_hedge_01) is identical on both EAs so they listen to the same files.
Key Parameters
InpRole	                   Sets the EA instance as ROLE_SIGNAL (0) or ROLE_FOLLOWER (1).
InpChannel                 The IPC channel name used to prefix shared CSV files. 
InpTimerMs                 The polling frequency in milliseconds (Default: 10).
InpFollowerHedgeMode       If true, a Signal BUY triggers a Follower SELL, and vice versa.
InpMaxPeerQuoteAgeMs       The maximum acceptable age for a peer quote before blocking trades (Default: 500ms).
InpBlockDuplicateSignal    Prevents the follower from executing the same command ID multiple times.
