// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

contract LidoAnomalyResponseHandler {
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

    struct IncidentReport {
        WithdrawalAnomalyData data;
        string message;
        uint256 reportId;
        address reporter; // who sent the response
    }

    event AnomalyAlert(
        address indexed reporter,
        uint256 queueLength,
        RiskLevel riskLevel,
        uint256 riskScore,
        uint256 timestamp
    );
    event ReportStored(uint256 indexed reportId, address indexed reporter, bytes encodedData, string message);
    event PauseSimulated(bool canPause, uint256 queuedEther);

    IncidentReport[] public reports;
    uint256 public nextReportId = 1;
    mapping(address => uint256[]) public userReports;

    // Processes message + data, logs, emits
    // Signature kept as (string, bytes) to match drosera.toml
    function handleWithdrawalAnomaly(string memory message, bytes calldata encodedData) external {
        (WithdrawalAnomalyData memory data) = abi.decode(encodedData, (WithdrawalAnomalyData));

        // attribute to msg.sender
        emit AnomalyAlert(
            msg.sender,
            data.queueLength,
            data.riskLevel,
            data.riskScore,
            data.timestamp
        );

        IncidentReport memory report = IncidentReport({
            data: data,
            message: message,
            reportId: nextReportId++,
            reporter: msg.sender
        });
        reports.push(report);
        userReports[msg.sender].push(report.reportId);

        emit ReportStored(report.reportId, msg.sender, encodedData, message);
    }

    // Simulate pause staking (stateful version with event emission)
    function simulatePause() external returns (bool canPause, string memory reason) {
        uint256 latestQueue = reports.length > 0
            ? reports[reports.length - 1].data.totalQueuedEther
            : 0;

        canPause = latestQueue > 1e20; // Example threshold
        reason = canPause ? "High queued Ether - pause recommended" : "Normal levels";

        emit PauseSimulated(canPause, latestQueue);
    }

    // Query functions for reports
    function getReportsLength() external view returns (uint256) {
        return reports.length;
    }

    function getReport(uint256 id) external view returns (IncidentReport memory) {
        require(id < reports.length, "Invalid ID");
        return reports[id];
    }
}
