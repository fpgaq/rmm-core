// SPDX-License-Identifier: GPL-3.0-only
pragma solidity 0.8.6;

/// @title   Primitive Engine
/// @author  Primitive
/// @dev     Replicating Market Maker

import "./libraries/ABDKMath64x64.sol";
import "./libraries/Margin.sol";
import "./libraries/Position.sol";
import "./libraries/ReplicationMath.sol";
import "./libraries/Reserve.sol";
import "./libraries/SafeCast.sol";
import "./libraries/Transfers.sol";
import "./libraries/Units.sol";

import "./interfaces/callback/IPrimitiveCreateCallback.sol";
import "./interfaces/callback/IPrimitiveBorrowCallback.sol";
import "./interfaces/callback/IPrimitiveDepositCallback.sol";
import "./interfaces/callback/IPrimitiveLiquidityCallback.sol";
import "./interfaces/callback/IPrimitiveRepayCallback.sol";
import "./interfaces/callback/IPrimitiveSwapCallback.sol";
import "./interfaces/IERC20.sol";
import "./interfaces/IPrimitiveEngine.sol";
import "./interfaces/IPrimitiveFactory.sol";

contract PrimitiveEngine is IPrimitiveEngine {
    using ABDKMath64x64 for *;
    using ReplicationMath for int128;
    using Units for *;
    using SafeCast for *;
    using Reserve for mapping(bytes32 => Reserve.Data);
    using Reserve for Reserve.Data;
    using Margin for mapping(address => Margin.Data);
    using Margin for Margin.Data;
    using Position for mapping(bytes32 => Position.Data);
    using Position for Position.Data;
    using Transfers for IERC20;

    /// @dev Parameters of each pool
    struct Calibration {
        uint128 strike; // strike price of the option
        uint64 sigma; // volatility of the option, scaled by Mantissa of 1e4
        uint32 maturity; // maturity timestamp of option
        uint32 lastTimestamp; // last timestamp used to calculate time until expiry, "tau"
    }

    /// @inheritdoc IPrimitiveEngineView
    address public immutable override factory;
    /// @inheritdoc IPrimitiveEngineView
    address public immutable override risky;
    /// @inheritdoc IPrimitiveEngineView
    address public immutable override stable;
    /// @inheritdoc IPrimitiveEngineView
    mapping(bytes32 => Calibration) public override calibrations;
    /// @inheritdoc IPrimitiveEngineView
    mapping(address => Margin.Data) public override margins;
    /// @inheritdoc IPrimitiveEngineView
    mapping(bytes32 => Position.Data) public override positions;
    /// @inheritdoc IPrimitiveEngineView
    mapping(bytes32 => Reserve.Data) public override reserves;

    uint8 private unlocked = 1;

    modifier lock() {
        if (unlocked != 1) revert LockedError();

        unlocked = 0;
        _;
        unlocked = 1;
    }

    /// @notice Deploys an Engine with two tokens, a 'Risky' and 'Stable'
    constructor() {
        (factory, risky, stable) = IPrimitiveFactory(msg.sender).args();
    }

    /// @return Risky token balance of this contract
    function balanceRisky() private view returns (uint256) {
        (bool success, bytes memory data) = risky.staticcall(
            abi.encodeWithSelector(IERC20.balanceOf.selector, address(this))
        );
        if (!success && data.length < 32) revert BalanceError();
        return abi.decode(data, (uint256));
    }

    /// @return Stable token balance of this contract
    function balanceStable() private view returns (uint256) {
        (bool success, bytes memory data) = stable.staticcall(
            abi.encodeWithSelector(IERC20.balanceOf.selector, address(this))
        );
        if (!success && data.length < 32) revert BalanceError();
        return abi.decode(data, (uint256));
    }

    /// @return blockTimestamp casted as a uint32
    function _blockTimestamp() internal view virtual returns (uint32 blockTimestamp) {
        // solhint-disable-next-line
        blockTimestamp = uint32(block.timestamp);
    }

    /// @inheritdoc IPrimitiveEngineActions
    function create(
        uint256 strike,
        uint64 sigma,
        uint32 maturity,
        uint256 delta,
        uint256 delLiquidity,
        bytes calldata data
    )
        external
        override
        lock
        returns (
            bytes32 poolId,
            uint256 delRisky,
            uint256 delStable
        )
    {
        poolId = keccak256(abi.encodePacked(address(this), strike, sigma, maturity));
        if (calibrations[poolId].lastTimestamp != 0) revert PoolDuplicateError();
        uint32 timestamp = _blockTimestamp();
        Calibration memory cal = Calibration({
            strike: strike.toUint128(),
            sigma: sigma,
            maturity: maturity,
            lastTimestamp: timestamp
        });

        uint32 tau = cal.maturity - timestamp; // time until expiry
        delRisky = 1e18 - delta; // 0 <= delta <= 1
        delStable = ReplicationMath.getStableGivenRisky(0, delRisky, cal.strike, cal.sigma, tau).parseUnits();
        delRisky = (delRisky * delLiquidity) / 1e18;
        delStable = (delStable * delLiquidity) / 1e18;
        if (delRisky * delStable == 0) revert CalibrationError(delRisky, delStable);

        (uint256 balRisky, uint256 balStable) = (balanceRisky(), balanceStable());
        IPrimitiveCreateCallback(msg.sender).createCallback(delRisky, delStable, data);
        if (balanceRisky() < delRisky + balRisky) revert RiskyBalanceError(delRisky + balRisky, balanceRisky());
        if (balanceStable() < delStable + balStable) revert StableBalanceError(delStable + balStable, balanceStable());

        calibrations[poolId] = cal; // initialize calibration
        reserves[poolId].allocate(delRisky, delStable, delLiquidity, timestamp); // provide liquidity
        positions.fetch(msg.sender, poolId).allocate(delLiquidity - 1000); // burn 1000 wei, at cost of msg.sender
        emit Created(msg.sender, cal.strike, cal.sigma, cal.maturity);
    }

    // ===== Margin =====

    /// @inheritdoc IPrimitiveEngineActions
    function deposit(
        address recipient,
        uint256 delRisky,
        uint256 delStable,
        bytes calldata data
    ) external override lock {
        uint256 balRisky;
        uint256 balStable;
        if (delRisky > 0) balRisky = balanceRisky();
        if (delStable > 0) balStable = balanceStable();
        IPrimitiveDepositCallback(msg.sender).depositCallback(delRisky, delStable, data); // agnostic payment
        if (balanceRisky() < balRisky + delRisky) revert RiskyBalanceError(balRisky + delRisky, balanceRisky());
        if (balanceStable() < balStable + delStable) revert StableBalanceError(balStable + delStable, balanceStable());

        margins[recipient].deposit(delRisky, delStable); // adds to risky and/or stable token balances
        emit Deposited(msg.sender, recipient, delRisky, delStable);
    }

    /// @inheritdoc IPrimitiveEngineActions
    function withdraw(
        address recipient,
        uint256 delRisky,
        uint256 delStable
    ) external override lock {
        margins.withdraw(delRisky, delStable); // removes risky and/or stable token balances from `msg.sender`
        if (delRisky > 0) IERC20(risky).safeTransfer(recipient, delRisky);
        if (delStable > 0) IERC20(stable).safeTransfer(recipient, delStable);
        emit Withdrawn(msg.sender, recipient, delRisky, delStable);
    }

    // ===== Liquidity =====

    /// @inheritdoc IPrimitiveEngineActions
    function allocate(
        bytes32 poolId,
        address recipient,
        uint256 delLiquidity,
        bool fromMargin,
        bytes calldata data
    ) external override lock returns (uint256 delRisky, uint256 delStable) {
        Reserve.Data storage reserve = reserves[poolId];

        if (reserve.blockTimestamp == 0) revert UninitializedError();
        delRisky = (delLiquidity * reserve.reserveRisky) / reserve.liquidity; // amount of risky tokens to provide
        delStable = (delLiquidity * reserve.reserveStable) / reserve.liquidity; // amount of stable tokens to provide
        if (delRisky * delStable == 0) revert ZeroDeltasError();

        if (fromMargin) {
            margins.withdraw(delRisky, delStable); // removes tokens from `msg.sender` margin account
        } else {
            (uint256 balRisky, uint256 balStable) = (balanceRisky(), balanceStable());
            IPrimitiveLiquidityCallback(msg.sender).allocateCallback(delRisky, delStable, data); // agnostic payment
            if (balanceRisky() < balRisky + delRisky) revert RiskyBalanceError(balRisky + delRisky, balanceRisky());
            if (balanceStable() < balStable + delStable)
                revert StableBalanceError(balStable + delStable, balanceStable());
        }

        positions.fetch(recipient, poolId).allocate(delLiquidity); // increase position liquidity
        reserve.allocate(delRisky, delStable, delLiquidity, _blockTimestamp()); // increase reserves and liquidity
        emit Allocated(msg.sender, recipient, poolId, delRisky, delStable);
    }

    /// @inheritdoc IPrimitiveEngineActions
    function remove(bytes32 poolId, uint256 delLiquidity)
        external
        override
        lock
        returns (uint256 delRisky, uint256 delStable)
    {
        Reserve.Data storage reserve = reserves[poolId];
        delRisky = (delLiquidity * reserve.reserveRisky) / reserve.liquidity; // amount of risky tokens to remove
        delStable = (delLiquidity * reserve.reserveStable) / reserve.liquidity; // amount of stable tokens to remove
        if (delRisky * delStable == 0) revert ZeroDeltasError();

        positions.remove(poolId, delLiquidity); // update position liquidity of msg.sender
        reserve.remove(delRisky, delStable, delLiquidity, _blockTimestamp()); // update global reserves
        margins[msg.sender].deposit(delRisky, delStable); // increase margin balance of msg.sender
        emit Removed(msg.sender, poolId, delRisky, delStable);
    }

    struct SwapDetails {
        bytes32 poolId;
        uint256 deltaIn;
        bool riskyForStable;
        bool fromMargin;
    }

    /// @inheritdoc IPrimitiveEngineActions
    function swap(
        bytes32 poolId,
        bool riskyForStable,
        uint256 deltaIn,
        bool fromMargin,
        bytes calldata data
    ) external override lock returns (uint256 deltaOut) {
        if (deltaIn == 0) revert DeltaInError();

        SwapDetails memory details = SwapDetails({
            poolId: poolId,
            deltaIn: deltaIn,
            riskyForStable: riskyForStable,
            fromMargin: fromMargin
        });

        // 0. Important: Update the lastTimestamp, effectively updating the time until expiry of the option
        uint32 timestamp = _blockTimestamp();
        if (timestamp > calibrations[details.poolId].maturity + 120) revert PoolExpiredError();
        calibrations[details.poolId].lastTimestamp = timestamp;
        emit UpdatedTimestamp(details.poolId, timestamp);
        // 1. Calculate invariant using the new time until expiry, tau = maturity - lastTimestamp
        int128 invariant = invariantOf(details.poolId);
        Reserve.Data storage reserve = reserves[details.poolId];
        (uint256 resRisky, uint256 resStable) = (reserve.reserveRisky, reserve.reserveStable);

        // 2. Calculate swapOut token reserve using new invariant + new time until expiry + new swapIn reserve
        // 3. Calculate difference of old swapOut token reserve and new swapOut token reserve to get swapOut amount
        if (details.riskyForStable) {
            uint256 nextRisky = ((resRisky + ((details.deltaIn * 9985) / 1e4)) * 1e18) / reserve.liquidity;
            uint256 nextStable = ((getStableGivenRisky(details.poolId, nextRisky).parseUnits() * reserve.liquidity) /
                1e18);
            deltaOut = resStable - nextStable;
        } else {
            uint256 nextStable = ((resStable + ((details.deltaIn * 9985) / 1e4)) * 1e18) / reserve.liquidity;
            uint256 nextRisky = (getRiskyGivenStable(details.poolId, nextStable).parseUnits() * reserve.liquidity) /
                1e18;
            deltaOut = resRisky - nextRisky;
        }

        if (deltaOut == 0) revert DeltaOutError();

        {
            // avoids stack too deep errors
            uint256 amountOut = deltaOut;
            (uint256 balRisky, uint256 balStable) = (balanceRisky(), balanceStable());
            if (details.riskyForStable) {
                IERC20(stable).safeTransfer(msg.sender, amountOut); // send proceeds, for callback if needed
                if (details.fromMargin) {
                    margins.withdraw(deltaIn, 0); // pay for swap
                } else {
                    IPrimitiveSwapCallback(msg.sender).swapCallback(details.deltaIn, 0, data); // agnostic payment
                    if (balanceRisky() < balRisky + details.deltaIn)
                        revert RiskyBalanceError(balRisky + details.deltaIn, balanceRisky());
                }
                if (balanceStable() < balStable - amountOut)
                    revert StableBalanceError(balStable - amountOut, balanceStable());
            } else {
                IERC20(risky).safeTransfer(msg.sender, amountOut); // send proceeds first, for callback if needed
                if (details.fromMargin) {
                    margins.withdraw(0, deltaIn); // pay for swap
                } else {
                    IPrimitiveSwapCallback(msg.sender).swapCallback(0, details.deltaIn, data); // agnostic payment
                    if (balanceStable() < balStable + details.deltaIn)
                        revert StableBalanceError(balStable + details.deltaIn, balanceStable());
                }
                if (balanceRisky() < balRisky - amountOut)
                    revert RiskyBalanceError(balRisky - amountOut, balanceRisky());
            }

            reserve.swap(details.riskyForStable, details.deltaIn, amountOut, timestamp);
            int128 nextInvariant = invariantOf(details.poolId); // 4. Important: do invariant check
            if (invariant > nextInvariant && nextInvariant.sub(invariant) >= Units.MANTISSA_INT)
                revert InvariantError(invariant, nextInvariant);
            emit Swap(msg.sender, details.poolId, details.riskyForStable, details.deltaIn, amountOut);
        }
    }

    // ===== Convexity =====

    /// @inheritdoc IPrimitiveEngineActions
    function supply(bytes32 poolId, uint256 delLiquidity) external override lock {
        if (delLiquidity == 0) revert ZeroLiquidityError();
        positions.supply(poolId, delLiquidity); // increase position float by `delLiquidity`
        reserves[poolId].addFloat(delLiquidity); // increase global float
        emit Supplied(msg.sender, poolId, delLiquidity);
    }

    /// @inheritdoc IPrimitiveEngineActions
    function claim(bytes32 poolId, uint256 delLiquidity) external override lock {
        if (delLiquidity == 0) revert ZeroLiquidityError();
        positions.claim(poolId, delLiquidity); // reduce float by `delLiquidity`
        reserves[poolId].removeFloat(delLiquidity); // reduce global float
        emit Claimed(msg.sender, poolId, delLiquidity);
    }

    /// @inheritdoc IPrimitiveEngineActions
    function borrow(
        bytes32 poolId,
        uint256 riskyCollateral,
        uint256 stableCollateral,
        bool fromMargin,
        bytes calldata data
    )
        external
        override
        lock
        returns (
            uint256 delRisky,
            uint256 delStable,
            uint256 riskyDeficit,
            uint256 stableDeficit
        )
    {
        // Source: Convex Payoff Approximation. https://stanford.edu/~guillean/papers/cfmm-lending.pdf. Section 5.
        if (riskyCollateral * stableCollateral == 0) revert ZeroLiquidityError();

        // 0. Calculate total amount of liquidity to borrow, sum of risky collateral and stable / K
        uint256 strike = uint256(calibrations[poolId].strike);
        uint256 delLiquidity = riskyCollateral + (stableCollateral * 1e18) / strike;

        // 1. Removing `delLiquidity` will yield how many risky and stable tokens?
        Reserve.Data storage reserve = reserves[poolId];
        delRisky = (delLiquidity * reserve.reserveRisky) / reserve.liquidity; // amount of risky from removing
        delStable = (delLiquidity * reserve.reserveStable) / reserve.liquidity; // amount of stable from removing

        // 2. Update state of global liquidity and position
        positions.borrow(poolId, riskyCollateral, stableCollateral); // incr. risky and stable collateral in position
        reserve.borrowFloat(delLiquidity); // decr. global float, incr. global debt,
        reserve.remove(delRisky, delStable, delLiquidity, _blockTimestamp()); // remove liquidity

        // 3. Calculate excess quantities from removing liquidity, or deficits to be paid
        uint256 riskyExcess; // 0 if risky deficit
        uint256 stableExcess; // 0 if stable deficit

        if (delRisky > riskyCollateral) riskyExcess = delRisky - riskyCollateral;
        if (riskyCollateral > delRisky) riskyDeficit = riskyCollateral - delRisky;
        if (delStable > stableCollateral) stableExcess = delStable - stableCollateral;
        if (stableCollateral > delStable) stableDeficit = stableCollateral - delStable;

        // 4. Pay out excess, and request deficits to be paid from margin or callbacks
        (uint256 balRisky, uint256 balStable) = (balanceRisky(), balanceStable()); // balance ref
        if (fromMargin) {
            margins.withdraw(riskyDeficit, stableDeficit); // pay deficits by withdrawing margin balance
            margins[msg.sender].deposit(riskyExcess, stableExcess); // deposit excess tokens from removed liquidity
        } else {
            if (riskyExcess > 0) IERC20(risky).safeTransfer(msg.sender, riskyExcess); // pay excess
            if (stableExcess > 0) IERC20(stable).safeTransfer(msg.sender, stableExcess);

            IPrimitiveBorrowCallback(msg.sender).borrowCallback(riskyDeficit, stableDeficit, data); // request deficits
            // keep in mind, if riskyDeficit > 0, then riskyExcess is 0, and same for stable
            if (balanceRisky() < balRisky + riskyDeficit - riskyExcess)
                revert RiskyBalanceError(balRisky + riskyDeficit - riskyExcess, balanceRisky());
            if (balanceStable() < balStable + stableDeficit - stableExcess)
                revert StableBalanceError(balStable + stableDeficit - stableExcess, balanceStable());
        }

        emit Borrowed(msg.sender, poolId, delLiquidity, riskyDeficit);
    }

    struct RepayDetails {
        bytes32 poolId;
        address recipient;
        uint256 riskyToLiquidate;
        uint256 stableToLiquidate;
        uint32 timestamp;
    }

    /// @inheritdoc IPrimitiveEngineActions
    /// @dev    Important: If the pool is expired, any position can be repaid to the position owner
    function repay(
        bytes32 poolId,
        address recipient,
        uint256 riskyToLiquidate,
        uint256 stableToLiquidate,
        bool fromMargin,
        bytes calldata data
    ) external override lock returns (uint256 riskyDeficit, uint256 stableDeficit) {
        RepayDetails memory details = RepayDetails({
            poolId: poolId,
            recipient: msg.sender,
            riskyToLiquidate: riskyToLiquidate,
            stableToLiquidate: stableToLiquidate,
            timestamp: _blockTimestamp()
        });
        Calibration memory cal = calibrations[details.poolId];
        {
            // account scope
            bool expired = details.timestamp >= cal.maturity;
            if (expired) details.recipient = recipient;
        }

        uint256 riskyExcess;
        uint256 stableExcess;
        {
            // liquidity scope
            Reserve.Data storage reserve = reserves[details.poolId];
            // 0. Calculate the amount of LP debt to be repaid
            uint256 delLiquidity = details.riskyToLiquidate + (details.stableToLiquidate * 1e18) / uint256(cal.strike); // Debt sum to repay
            // 1. Calculate the amount of risky and stable tokens needed to mint `delLiquidity` of LP
            uint256 delRisky = (delLiquidity * reserve.reserveRisky) / reserve.liquidity; // amount of risky required to allocate
            uint256 delStable = (delLiquidity * reserve.reserveStable) / reserve.liquidity; // amount of stable required to allocate
            // 2. Update the global reserve with the allocated liquidity
            reserve.repayFloat(delLiquidity); // increase reserve float, decrease reserve debt
            reserve.allocate(delRisky, delStable, delLiquidity, details.timestamp); // increase: risky, stable, and liquidity
            // 3. Calculate the differences between tokens to needed to allocate and amount of collateral to withdraw
            if (details.riskyToLiquidate > delRisky) riskyExcess = details.riskyToLiquidate - delRisky;
            if (delRisky > details.riskyToLiquidate) riskyDeficit = delRisky - details.riskyToLiquidate;
            if (details.stableToLiquidate > delStable) stableExcess = details.stableToLiquidate - delStable;
            if (delStable > details.stableToLiquidate) stableDeficit = delStable - details.stableToLiquidate;
            // 4. If paying with margin, do so within this scope
            if (fromMargin) margins.withdraw(delRisky, delStable);
        }

        {
            // payment scope
            if (fromMargin) {
                margins[details.recipient].deposit(uint256(riskyDeficit), uint256(stableDeficit)); // send remainder of risky to margin
            } else {
                (uint256 balRisky, uint256 balStable) = (balanceRisky(), balanceStable()); // use as a ref
                if (riskyExcess > 0) IERC20(risky).safeTransfer(details.recipient, riskyExcess); // pay excess
                if (stableExcess > 0) IERC20(stable).safeTransfer(details.recipient, stableExcess);

                IPrimitiveRepayCallback(msg.sender).repayCallback(uint256(riskyDeficit), uint256(stableDeficit), data); // request deficits
                // keep in mind, if riskyDeficit > 0, then riskyExcess is 0
                if (balanceRisky() < balRisky + uint256(riskyDeficit) - riskyExcess)
                    revert RiskyBalanceError(balRisky + uint256(riskyDeficit) - riskyExcess, balanceRisky());
                if (balanceStable() < balStable + uint256(stableDeficit) - stableExcess)
                    revert StableBalanceError(balStable + uint256(stableDeficit) - stableExcess, balanceStable());
            }
        }

        emit Repaid(msg.sender, details.recipient, details.poolId, riskyDeficit, stableDeficit);
    }

    // ===== Swap and Liquidity Math =====

    /// @inheritdoc IPrimitiveEngineView
    function getStableGivenRisky(bytes32 poolId, uint256 reserveRisky)
        public
        view
        override
        returns (int128 reserveStable)
    {
        Calibration memory cal = calibrations[poolId];
        int128 invariantLast = invariantOf(poolId);
        uint256 tau;
        if (cal.maturity > cal.lastTimestamp) tau = cal.maturity - cal.lastTimestamp; // invariantOf() uses this
        reserveStable = ReplicationMath.getStableGivenRisky(invariantLast, reserveRisky, cal.strike, cal.sigma, tau);
    }

    /// @inheritdoc IPrimitiveEngineView
    function getRiskyGivenStable(bytes32 poolId, uint256 reserveStable)
        public
        view
        override
        returns (int128 reserveRisky)
    {
        Calibration memory cal = calibrations[poolId];
        int128 invariantLast = invariantOf(poolId);
        uint256 tau;
        if (cal.maturity > cal.lastTimestamp) tau = cal.maturity - cal.lastTimestamp; // invariantOf() uses this
        reserveRisky = ReplicationMath.getRiskyGivenStable(invariantLast, reserveStable, cal.strike, cal.sigma, tau);
    }

    // ===== View =====

    /// @inheritdoc IPrimitiveEngineView
    function invariantOf(bytes32 poolId) public view override returns (int128 invariant) {
        Reserve.Data memory res = reserves[poolId];
        Calibration memory cal = calibrations[poolId];
        uint256 reserveRisky = (res.reserveRisky * 1e18) / res.liquidity; // risky per 1 liquidity
        uint256 reserveStable = (res.reserveStable * 1e18) / res.liquidity; // stable per 1 liquidity
        uint256 tau;
        if (cal.maturity > cal.lastTimestamp) tau = cal.maturity - cal.lastTimestamp;
        invariant = ReplicationMath.calcInvariant(reserveRisky, reserveStable, cal.strike, cal.sigma, tau);
    }
}
