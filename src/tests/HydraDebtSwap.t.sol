// SPDX-License-Identifier: MIT
pragma solidity ^0.8.10;

import {IERC20Detailed} from '@aave/core-v3/contracts/dependencies/openzeppelin/contracts/IERC20Detailed.sol';
import {IPoolAddressesProvider} from '@aave/core-v3/contracts/interfaces/IPoolAddressesProvider.sol';
import {ICreditDelegationToken} from '@aave/core-v3/contracts/interfaces/ICreditDelegationToken.sol';
import {AaveGovernanceV2} from 'aave-address-book/AaveGovernanceV2.sol';
import {AaveV3Ethereum, AaveV3EthereumAssets, IPool} from 'aave-address-book/AaveV3Ethereum.sol';
import {IParaSwapDebtSwapAdapter} from 'src/contracts/interfaces/IParaSwapDebtSwapAdapter.sol';
import {ParaSwapDebtSwapAdapterV3} from 'src/contracts/ParaSwapDebtSwapAdapterV3.sol';
import {IParaSwapAugustusRegistry} from 'src/contracts/dependencies/paraswap/IParaSwapAugustusRegistry.sol';
import {HydraAugustus} from 'src/contracts/hydra/HydraAugustus.sol';
import {HydraAugustusRegistry} from 'src/contracts/hydra/HydraAugustusRegistry.sol';
import {MockDispatchPrecompile} from './mocks/MockDispatchPrecompile.sol';
import {BaseTest} from './utils/BaseTest.sol';

contract HydraDebtSwapTest is BaseTest {
    HydraAugustus internal hydraAugustus;
    HydraAugustusRegistry internal hydraRegistry;
    MockDispatchPrecompile internal mockDispatch;
    ParaSwapDebtSwapAdapterV3 internal debtSwapAdapter;

    uint32 internal constant LUSD_ASSET_ID = 1;
    uint32 internal constant DAI_ASSET_ID = 2;
    uint8 internal constant BUY_CALL_INDEX = 1; // pallet_route::Call::buy (conventional ordering; confirm vs runtime metadata)
    uint8 internal constant PALLET_INDEX = 67; // Hydration Router pallet (construct_runtime: Router = 67, DcaDispatch.ROUTER_PALLET)

    function setUp() public override {
        super.setUp();
        vm.createSelectFork(vm.rpcUrl('mainnet'), 17786869);

        mockDispatch = new MockDispatchPrecompile();
        hydraAugustus = new HydraAugustus(address(mockDispatch));
        hydraRegistry = new HydraAugustusRegistry(address(hydraAugustus));

        debtSwapAdapter = new ParaSwapDebtSwapAdapterV3(
            IPoolAddressesProvider(address(AaveV3Ethereum.POOL_ADDRESSES_PROVIDER)),
            address(AaveV3Ethereum.POOL),
            IParaSwapAugustusRegistry(address(hydraRegistry)),
            AaveGovernanceV2.SHORT_EXECUTOR
        );

        mockDispatch.setAssetMapping(LUSD_ASSET_ID, AaveV3EthereumAssets.LUSD_UNDERLYING);
        mockDispatch.setAssetMapping(DAI_ASSET_ID, AaveV3EthereumAssets.DAI_UNDERLYING);
        mockDispatch.setRate(1e18, 1e18);
    }

    function test_debtSwap_swapHalf() public {
        address debtAsset = AaveV3EthereumAssets.DAI_UNDERLYING;
        address newDebtAsset = AaveV3EthereumAssets.LUSD_UNDERLYING;
        uint256 repayAmount = 500 ether;
        uint256 maxNewDebt = (repayAmount * 110) / 100;

        vm.startPrank(user);
        _supply(AaveV3Ethereum.POOL, 200_000 ether, debtAsset);
        _borrow(AaveV3Ethereum.POOL, 1000 ether, debtAsset);

        deal(debtAsset, address(mockDispatch), repayAmount);

        ICreditDelegationToken(AaveV3EthereumAssets.LUSD_V_TOKEN).approveDelegation(
            address(debtSwapAdapter),
            maxNewDebt
        );

        uint256 oldDebtBefore = IERC20Detailed(AaveV3EthereumAssets.DAI_V_TOKEN).balanceOf(user);

        _executeDebtSwap(debtAsset, newDebtAsset, repayAmount, maxNewDebt, 0);

        assertApproxEqAbs(
            IERC20Detailed(AaveV3EthereumAssets.DAI_V_TOKEN).balanceOf(user),
            oldDebtBefore - repayAmount,
            1
        );
        assertLe(
            IERC20Detailed(AaveV3EthereumAssets.LUSD_V_TOKEN).balanceOf(user),
            maxNewDebt
        );
        _invariant(address(debtSwapAdapter), debtAsset, newDebtAsset);
        _assertAugustusClean(debtAsset, newDebtAsset);
    }

    function test_debtSwap_swapAll() public {
        address debtAsset = AaveV3EthereumAssets.DAI_UNDERLYING;
        address newDebtAsset = AaveV3EthereumAssets.LUSD_UNDERLYING;

        vm.startPrank(user);
        _supply(AaveV3Ethereum.POOL, 200_000 ether, debtAsset);
        _borrow(AaveV3Ethereum.POOL, 1000 ether, debtAsset);

        skip(1 hours);

        uint256 repayAmount = (1000 ether * 101) / 100;
        uint256 maxNewDebt = (repayAmount * 110) / 100;

        deal(debtAsset, address(mockDispatch), repayAmount);

        ICreditDelegationToken(AaveV3EthereumAssets.LUSD_V_TOKEN).approveDelegation(
            address(debtSwapAdapter),
            maxNewDebt
        );

        _executeDebtSwap(debtAsset, newDebtAsset, type(uint256).max, maxNewDebt, 100);

        assertEq(IERC20Detailed(AaveV3EthereumAssets.DAI_V_TOKEN).balanceOf(user), 0);
        assertLe(
            IERC20Detailed(AaveV3EthereumAssets.LUSD_V_TOKEN).balanceOf(user),
            maxNewDebt
        );
        _invariant(address(debtSwapAdapter), debtAsset, newDebtAsset);
        _assertAugustusClean(debtAsset, newDebtAsset);
    }

    function test_revert_invalidAugustus() public {
        address debtAsset = AaveV3EthereumAssets.DAI_UNDERLYING;
        address newDebtAsset = AaveV3EthereumAssets.LUSD_UNDERLYING;
        uint256 repayAmount = 500 ether;
        uint256 maxNewDebt = (repayAmount * 110) / 100;

        vm.startPrank(user);
        _supply(AaveV3Ethereum.POOL, 200_000 ether, debtAsset);
        _borrow(AaveV3Ethereum.POOL, 1000 ether, debtAsset);

        ICreditDelegationToken(AaveV3EthereumAssets.LUSD_V_TOKEN).approveDelegation(
            address(debtSwapAdapter),
            maxNewDebt
        );

        bytes memory paraswapData = abi.encode(
            abi.encodeWithSelector(
                HydraAugustus.buy.selector,
                newDebtAsset,
                debtAsset,
                maxNewDebt,
                repayAmount,
                _buildBuyDispatchData(LUSD_ASSET_ID, DAI_ASSET_ID, repayAmount, maxNewDebt)
            ),
            address(0xDEAD)
        );

        IParaSwapDebtSwapAdapter.DebtSwapParams memory params = IParaSwapDebtSwapAdapter
            .DebtSwapParams({
                debtAsset: debtAsset,
                debtRepayAmount: repayAmount,
                debtRateMode: 2,
                newDebtAsset: newDebtAsset,
                maxNewDebtAmount: maxNewDebt,
                extraCollateralAsset: address(0),
                extraCollateralAmount: 0,
                offset: 0,
                paraswapData: paraswapData
            });

        IParaSwapDebtSwapAdapter.CreditDelegationInput memory cd;
        IParaSwapDebtSwapAdapter.PermitInput memory collateralATokenPermit;

        vm.expectRevert(bytes('INVALID_AUGUSTUS'));
        debtSwapAdapter.swapDebt(params, cd, collateralATokenPermit);
    }

    function _executeDebtSwap(
        address debtAsset,
        address newDebtAsset,
        uint256 debtRepayAmount,
        uint256 maxNewDebt,
        uint256 offset
    ) internal {
        bytes memory paraswapData = _buildParaswapData(
            newDebtAsset,
            debtAsset,
            maxNewDebt,
            debtRepayAmount
        );

        IParaSwapDebtSwapAdapter.DebtSwapParams memory params = IParaSwapDebtSwapAdapter
            .DebtSwapParams({
                debtAsset: debtAsset,
                debtRepayAmount: debtRepayAmount,
                debtRateMode: 2,
                newDebtAsset: newDebtAsset,
                maxNewDebtAmount: maxNewDebt,
                extraCollateralAsset: address(0),
                extraCollateralAmount: 0,
                offset: offset,
                paraswapData: paraswapData
            });

        IParaSwapDebtSwapAdapter.CreditDelegationInput memory cd;
        IParaSwapDebtSwapAdapter.PermitInput memory collateralATokenPermit;

        debtSwapAdapter.swapDebt(params, cd, collateralATokenPermit);
    }

    function _assertAugustusClean(address debtAsset, address newDebtAsset) internal {
        assertEq(IERC20Detailed(debtAsset).balanceOf(address(hydraAugustus)), 0);
        assertEq(IERC20Detailed(newDebtAsset).balanceOf(address(hydraAugustus)), 0);
    }

    function _supply(IPool pool, uint256 amount, address asset) internal {
        deal(asset, user, amount);
        IERC20Detailed(asset).approve(address(pool), amount);
        pool.supply(asset, amount, user, 0);
    }

    function _borrow(IPool pool, uint256 amount, address asset) internal {
        pool.borrow(asset, amount, 2, 0, user);
    }

    function _buildParaswapData(
        address tokenIn,
        address tokenOut,
        uint256 maxAmountIn,
        uint256 amountOut
    ) internal view returns (bytes memory) {
        bytes memory dispatchData = _buildBuyDispatchData(
            LUSD_ASSET_ID,
            DAI_ASSET_ID,
            amountOut,
            maxAmountIn
        );
        bytes memory buyCalldata = abi.encodeWithSelector(
            HydraAugustus.buy.selector,
            tokenIn,
            tokenOut,
            maxAmountIn,
            amountOut,
            dispatchData
        );
        return abi.encode(buyCalldata, address(hydraAugustus));
    }

    function _buildBuyDispatchData(
        uint32 assetInId,
        uint32 assetOutId,
        uint256 amountOut,
        uint256 maxAmountIn
    ) internal pure returns (bytes memory data) {
        data = new bytes(42);
        data[0] = bytes1(PALLET_INDEX);
        data[1] = bytes1(BUY_CALL_INDEX);
        _writeU32LE(data, 2, assetInId);
        _writeU32LE(data, 6, assetOutId);
        _writeU128LE(data, 10, amountOut);
        _writeU128LE(data, 26, maxAmountIn);
    }

    function _writeU32LE(bytes memory data, uint256 offset, uint32 value) internal pure {
        data[offset] = bytes1(uint8(value));
        data[offset + 1] = bytes1(uint8(value >> 8));
        data[offset + 2] = bytes1(uint8(value >> 16));
        data[offset + 3] = bytes1(uint8(value >> 24));
    }

    function _writeU128LE(bytes memory data, uint256 offset, uint256 value) internal pure {
        for (uint256 i = 0; i < 16; i++) {
            data[offset + i] = bytes1(uint8(value >> (i * 8)));
        }
    }
}
