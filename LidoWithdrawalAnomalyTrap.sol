// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {ITrap} from "drosera-contracts/interfaces/ITrap.sol";

interface IWithdrawalQueue {
    function getTotalShares(address owner) external view returns (uint256);
    function getTotalPooledEther() external view returns (uint256);
    function getQueueLength() external view returns (uint256);
    function getWithdrawalQueue() external view returns (uint256[] memory timestamps);
}

interface IStETH {
    function totalSupply() external view returns (uint256);
}

interface IStakingRouter {
    function getTotalPooledEther() external view returns (uint256);
}

contract LidoWithdrawalAnomalyTrap is ITrap {
    // Constants: No constructor args; all hardcoded for PoC
    address public constant WITHDRAWAL_QUEUE = 0xfe56573178f1bcdf53F01A6E9977670dcBBD9186;
    address public constant STETH_TOKEN = 0x3508A952176b3c15387C97BE809eaffB1982176a;
    address public constant STAKING_ROUTER = 0xCc820558B39ee15C7C45B59390B503b83fb499A8;
    address public constant MONITORED_USER = 0xF0179dEC45a37423EAD4FaD5fCb136197872EAd9;
    uint256 public constant QUEUE_LENGTH_THRESHOLD = 1000;
    uint256 public constant TOTAL_QUEUED_IMPACT_THRESHOLD = 1e20;
    uint256 public constant USER_SHARES_THRESHOLD = 500 * 1e18;
    uint256 public constant VELOCITY_WINDOW_BLOCKS = 10;
    uint256 public constant RISK_WEIGHT_QUEUE = 40;
    uint256 public constant RISK_WEIGHT_USER = 30;
    uint256 public constant RISK_WEIGHT_IMPACT = 30;

    enum RiskLevel { LOW, MEDIUM, HIGH, CRITICAL }

    struct WithdrawalAnomalyData {
        uint256 queueLength;
        uint256 totalQueuedShares;
        uint256 totalQueuedEther;
        uint256 userShares;
        uint256 totalStETHSupply;
        uint256 velocityDelta;
        RiskLevel riskLevel;
        uint256 riskScore;
        uint256 timestamp;
        bool isUserAnomalous;
    }

    string constant MESSAGE = "Lido Withdrawal Anomaly Detected on Hoodi - Potential Mass Exit or Whale Risk";

    function _getQueueMetrics() internal view returns (uint256 length, uint256 totalShares, uint256 totalEther) {
        try IWithdrawalQueue(WITHDRAWAL_QUEUE).getQueueLength() returns (uint256 l) {
            length = l;
        } catch {
            length = 0;
        }

        try IWithdrawalQueue(WITHDRAWAL_QUEUE).getTotalPooledEther() returns (uint256 e) {
            totalEther = e;
        } catch {
            totalEther = 0;
        }

        try IWithdrawalQueue(WITHDRAWAL_QUEUE).getWithdrawalQueue() returns (uint256[] memory timestamps) {
            totalShares = timestamps.length;
        } catch {
            totalShares = 0;
        }
    }

    function _checkUserAnomaly() internal view returns (uint256 userShares, bool isAnomalous) {
        try IWithdrawalQueue(WITHDRAWAL_QUEUE).getTotalShares(MONITORED_USER) returns (uint256 shares) {
            userShares = shares;
            isAnomalous = shares > USER_SHARES_THRESHOLD;
        } catch {
            userShares = 0;
            isAnomalous = false;
        }
    }

    function _calculateVelocity() internal pure returns (uint256 delta) {
        delta = 0;
    }

    function collect() external view override returns (bytes memory) {
        (uint256 queueLength, uint256 totalQueuedShares, uint256 totalQueuedEther) = _getQueueMetrics();
        (uint256 userShares, bool isUserAnomalous) = _checkUserAnomaly();
        uint256 totalStETHSupply = IStETH(STETH_TOKEN).totalSupply();
        uint256 velocityDelta = _calculateVelocity();

        uint256 queueScore = QUEUE_LENGTH_THRESHOLD > 0 ? (queueLength * 100) / QUEUE_LENGTH_THRESHOLD : 0;
        uint256 userScore = USER_SHARES_THRESHOLD > 0 ? (userShares * 100) / USER_SHARES_THRESHOLD : 0;
        uint256 impactScore = TOTAL_QUEUED_IMPACT_THRESHOLD > 0 ? (totalQueuedEther * 100) / TOTAL_QUEUED_IMPACT_THRESHOLD : 0;

        uint256 riskScore = (
            (queueScore * RISK_WEIGHT_QUEUE) / 100 +
            (userScore * RISK_WEIGHT_USER) / 100 +
            (impactScore * RISK_WEIGHT_IMPACT) / 100
        );

        if (riskScore > 100) {
            riskScore = 100;
        }

        RiskLevel riskLevel;
        if (riskScore >= 80 || (isUserAnomalous && velocityDelta > 0)) {
            riskLevel = RiskLevel.CRITICAL;
        } else if (riskScore >= 50) {
            riskLevel = RiskLevel.HIGH;
        } else if (riskScore >= 25) {
            riskLevel = RiskLevel.MEDIUM;
        } else {
            riskLevel = RiskLevel.LOW;
        }

        WithdrawalAnomalyData memory data = WithdrawalAnomalyData({
            queueLength: queueLength,
            totalQueuedShares: totalQueuedShares,
            totalQueuedEther: totalQueuedEther,
            userShares: userShares,
            totalStETHSupply: totalStETHSupply,
            velocityDelta: velocityDelta,
            riskLevel: riskLevel,
            riskScore: riskScore,
            timestamp: block.timestamp,
            isUserAnomalous: isUserAnomalous
        });

        return abi.encode(data);
    }

    // shouldRespond: now accepts single/dual/multi-sample inputs.
    function shouldRespond(bytes[] calldata data) external pure override returns (bool, bytes memory) {
        // If no data provided, bail
        if (data.length == 0) return (false, bytes(""));

        // decode latest
        WithdrawalAnomalyData memory latest = abi.decode(data[0], (WithdrawalAnomalyData));

        // SINGLE-SAMPLE fast path (mirrors AVS simplicity)
        if (data.length == 1) {
            // Fire if immediate thresholds met
            bool immediate = false;
            // riskScore threshold -> MEDIUM or above
            if (latest.riskScore >= 25) immediate = true;
            // queue length absolute threshold
            if (latest.queueLength >= QUEUE_LENGTH_THRESHOLD) immediate = true;
            // user anomaly
            if (latest.isUserAnomalous) immediate = true;

            if (immediate) {
                return (true, abi.encode(MESSAGE, abi.encode(latest)));
            } else {
                return (false, bytes(""));
            }
        }

        // TWO-SAMPLE relaxed trend check
        if (data.length == 2) {
            WithdrawalAnomalyData memory prev1 = abi.decode(data[1], (WithdrawalAnomalyData));
            bool trend = (latest.riskScore > prev1.riskScore) || latest.isUserAnomalous;
            // 10% spike: latest * 10 > prev1 * 11 (integer-safe)
            bool queueSpike = false;
            if (prev1.queueLength > 0) {
                queueSpike = (latest.queueLength * 10) > (prev1.queueLength * 11);
            }

            if ((uint8(latest.riskLevel) >= uint8(RiskLevel.MEDIUM) && (trend || queueSpike))) {
                return (true, abi.encode(MESSAGE, abi.encode(latest)));
            } else {
                return (false, bytes(""));
            }
        }

        // THREE+ SAMPLE: original time-series logic
        WithdrawalAnomalyData memory prev1 = abi.decode(data[1], (WithdrawalAnomalyData));
        WithdrawalAnomalyData memory prev2 = abi.decode(data[2], (WithdrawalAnomalyData));

        bool consecutiveIncrease = (latest.riskScore > prev1.riskScore && prev1.riskScore > prev2.riskScore);

        bool queueSpikeMulti = false;
        if (prev1.queueLength > 0) {
            queueSpikeMulti = (latest.queueLength * 10) > (prev1.queueLength * 11);
        }

        bool patternDetected = consecutiveIncrease || queueSpikeMulti || latest.isUserAnomalous;

        if (uint8(latest.riskLevel) >= uint8(RiskLevel.MEDIUM) && patternDetected) {
            return (true, abi.encode(MESSAGE, abi.encode(latest)));
        }
        return (false, bytes(""));
    }
}
