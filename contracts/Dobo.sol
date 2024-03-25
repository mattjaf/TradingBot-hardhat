//SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.0;

import "@uniswap/v2-periphery/contracts/interfaces/IUniswapV2Router02.sol";
import "@uniswap/v2-core/contracts/interfaces/IUniswapV2Pair.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "./GetPriceFeedData.sol";

//place the order
//check the order -- automatically fill the order
//execute the order
//modify and cancel the order

contract Dobo is Ownable {

    //address botAddress;
    IUniswapV2Router02[] public V2DexRouters;
    //IERC20[] public Aprroved2DexTokens;
    //address[] public approvedPriceFeedContracts;
    mapping(address => bool) public approvedDexTokens; //this might be a better way to do this
    mapping(address => bool) public approvedPriceFeedContracts; //this might be a better way to do this
    mapping(address => address) public TokenToPriceFeed;

    event OrderPlaced(address indexed user, uint256 amount, uint256 price);
    event OrderExecuted(address indexed user, uint256 amount, uint256 price);


    struct Order {
        address originTokenAddress; //stable
        address targetTokenAddress; //investment    
        uint256 amount; //amount of stable token
        uint256 PurchasePrice; //price of TargetToken in stable token -- expected amount
        uint256 SellPrice; //price of TargetToken in stable token
        uint256 slippage; //slippage of the order
        uint256 expirationDate; //expiration date of the order if the price never hits the purchase price -- how to clean?
        //bool active; //active or inactive -- is this the proper place for this?
    }
    /*
    decentralized order book
    each user has multiple orders
    orders are executed based on sell and buy price and execute an array of orders
    users can look up their orders, modify them, and cancel them
     */
    mapping(uint256 => uint256[]) private sellPriceToOrderID; //maybe to order ID
    mapping(uint256 => uint256[]) private purchasePriceToOrderID; //maybe to order ID
    mapping(uint256 => Order) private IDToOrder;
    mapping(address => uint256[]) private userToIDs; //count be be .length? 
    //mapping(address => uint256[]) private userToActiveOrderlist; //how does active and diactive orders work?
    mapping(uint256 => bool) public activeOrders;

    uint256 public orderCounter;

    constructor(IUniswapV2Router02[] memory _approvedDexRouters, address[] memory _approved2DexTokens, address[] memory _approvedPriceFeedContracts) {
        V2DexRouters = _approvedDexRouters;
        //Aprroved2DexTokens = _Approved2DexTokens; //there might be a better way to do this using the uniswap contracts -- unless using chainlink for price data?
        //approvedPriceFeedContracts = _approvedPriceFeedContracts;
        for (uint i = 0; i < _approved2DexTokens.length; i++) {
            approvedDexTokens[_approved2DexTokens[i]] = true;
        }
        for (uint i = 0; i < _approvedPriceFeedContracts.length; i++) {
            approvedPriceFeedContracts[_approvedPriceFeedContracts[i]] = true;
        }
    }

    function placeOrder(address _originTokenAddress, address _targetTokenAddress, uint256 _amount, uint256 _sellPrice, uint256 _purchasePrice, uint256 _slippage, uint256 _expirationDate) public {
        //is the token a valid trading pair within the uniswap contract? check to see if Dai to tokenAddress is a valid swap
        require(approvedDexTokens[_originTokenAddress] == true && approvedDexTokens[_targetTokenAddress] == true, "Token is not approved for trading");
        require(_amount > 0 || _purchasePrice > 0 || _sellPrice > 0, "Amount & Price must be greater than zero");
        require(_expirationDate > block.timestamp, "Expiration date must be in the future");
        require(IERC20(_originTokenAddress).balanceOf(msg.sender) >= _amount, "Insufficient balance");
        //pre-approved -- what about when it goes to spend?
        require(IERC20(_originTokenAddress).allowance(msg.sender, address(this)) >= _amount, "Insufficient allowance"); //preferably approved and/or stake in LP prior to execution

        Order memory newOrder = Order(_originTokenAddress, _targetTokenAddress, _amount, _purchasePrice, _sellPrice, _slippage, _expirationDate);
      
        orderCounter++;
        IDToOrder[orderCounter] = newOrder;
        purchasePriceToOrderID[orderCounter].push(orderCounter);
        userToIDs[msg.sender].push(orderCounter);
        activeOrders[orderCounter] = true; // why am tracking this again?

        emit OrderPlaced(msg.sender, _amount, _purchasePrice);
    }

    function purchaseOrder(uint256 _orderID) public {
        //require(IDToOrder[_orderID].active == true, "Order is not active"); //double check tracking optimization and data structure
        require(IDToOrder[_orderID].expirationDate > block.timestamp, "Order has expired");
        //require(IERC20(IDToOrder[_orderID].OriginTokenAddress).balanceOf(msg.sender) >= IDToOrder[_orderID].amount, "Insufficient balance");
        //require(IERC20(IDToOrder[_orderID].OriginTokenAddress).allowance(msg.sender, address(this)) >= IDToOrder[_orderID].amount, "Insufficient allowance");
        require(GetPriceFeedDataV8.getPrice(IDToOrder[_orderID].targetTokenAddress) <= IDToOrder[_orderID].PurchasePrice, "Price is too high");

        require(IERC20(IDToOrder[_orderID].originTokenAddress).transferFrom(msg.sender, address(this), IDToOrder[_orderID].amount), "Transfer failed");
        //IDToOrder[_orderID].active = false;

        bool swapSuccessful = trySwap(_orderID, IDToOrder[_orderID].amount, IDToOrder[_orderID].PurchasePrice);
    //option to stake or send? -- what if the swap fails?
        if (!swapSuccessful) {
            revert("All DEX swaps failed");
            // Optionally, handle the case where all swaps fail (e.g., refunding the user).
        }
    }

    function sellOrder(uint256 _orderID) public {
        //require(IDToOrder[_orderID].active == true, "Order is not active"); //double check tracking optimization and data structure
        require(IDToOrder[_orderID].expirationDate > block.timestamp, "Order has expired");
        require(GetPriceFeedDataV8.getPrice(IDToOrder[_orderID].targetTokenAddress) >= IDToOrder[_orderID].SellPrice, "Price is too low");

        require(IERC20(IDToOrder[_orderID].targetTokenAddress).transferFrom(msg.sender, address(this), IDToOrder[_orderID].amount), "Transfer failed");
        //IDToOrder[_orderID].active = false;

        bool swapSuccessful = trySwap(_orderID, IDToOrder[_orderID].amount, IDToOrder[_orderID].SellPrice);
        if (!swapSuccessful) {
            revert("All DEX swaps failed");
            // Optionally, handle the case where all swaps fail (e.g., refunding the user).
        }

    }
    

    function trySwap(uint _orderID, uint _amount, uint _price) internal returns (bool) {
        bool swapSuccessful = false;
        for (uint i = 0; i < V2DexRouters.length && !swapSuccessful; i++) {
            IUniswapV2Router02 uniswapRouter = IUniswapV2Router02(V2DexRouters[i]);
            address[] memory path = getPathForTokenToToken(IDToOrder[_orderID].originTokenAddress, IDToOrder[_orderID].targetTokenAddress);

            try uniswapRouter.getAmountsOut(_amount, path) returns (uint256[] memory amountsOut) {
                //is this right? and universal for both buy and sell? this might not be right
                uint256 expectedAmountOut = amountsOut[1] * (100 - IDToOrder[_orderID].slippage) / 100;
                if (_amount * _price >= expectedAmountOut) {
                    try uniswapRouter.swapExactTokensForTokens(
                        _amount,
                        expectedAmountOut,
                        path,
                        msg.sender,
                        block.timestamp + 1200
                    ) {
                        swapSuccessful = true; // Swap succeeded
                    } catch {
                        // Swap failed, continue to the next DEX
                    }
                }
            } catch {
                // Getting amounts out failed, continue to the next DEX
            }
        }
        return swapSuccessful;
    }

        //iterate over the buy and sell orders and check the price of the token arrays to see if the order needs to be placed

    

    //Thinking in terms of automation -- possibly using chainlink, possibly offchain, thinking scalablity.

    //if chainlink is used for automation it is going to check the price then execute the order

    function getPathForTokenToToken(address _token1, address _token2) public pure returns (address[] memory) {
        address[] memory path = new address[](2);
        path[0] = _token1;
        path[1] = _token2;
        return path;
    }


}
