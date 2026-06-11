// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

/// @notice Minimal Chainlink AggregatorV3Interface mock for tests and the
///         local anvil deployment.
contract MockV3Aggregator {
    uint8 public decimals;
    int256 public answer;
    uint256 public updatedAt;
    uint80 public roundId;

    constructor(uint8 decimals_, int256 answer_) {
        decimals = decimals_;
        setAnswer(answer_);
    }

    /// @notice set a fresh answer at the current block timestamp
    function setAnswer(int256 answer_) public {
        answer = answer_;
        updatedAt = block.timestamp;
        roundId++;
    }

    /// @notice set an answer with an arbitrary updatedAt (staleness tests)
    function setRaw(int256 answer_, uint256 updatedAt_) public {
        answer = answer_;
        updatedAt = updatedAt_;
        roundId++;
    }

    function setDecimals(uint8 decimals_) public {
        decimals = decimals_;
    }

    function latestRoundData()
        external
        view
        returns (uint80, int256, uint256, uint256, uint80)
    {
        return (roundId, answer, updatedAt, updatedAt, roundId);
    }
}
