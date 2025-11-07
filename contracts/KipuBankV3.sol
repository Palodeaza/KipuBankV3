// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;


// KipuBankV3



import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";

interface IUniswapV2Router02 {
    function WETH() external pure returns (address);

    function swapExactETHForTokens(
        uint amountOutMin,
        address[] calldata path,
        address to,
        uint deadline
    ) external payable returns (uint[] memory amounts);

    function swapExactTokensForTokens(
        uint amountIn,// SPDX-License-Identifier: MIT
        uint amountOutMin,
        address[] calldata path,
        address to,
        uint deadline
    ) external returns (uint[] memory amounts);

    // view
    function getAmountsOut(uint amountIn, address[] calldata path) external view returns (uint[] memory amounts);
}

contract KipuBankV3 is Ownable, ReentrancyGuard {
    using SafeERC20 for IERC20Metadata;

    IUniswapV2Router02 public router;
    IERC20Metadata public usdc;
    uint8 public usdcDecimals;

    // Bank cap in USDC smallest units (eg if USDC has 6 decimals, cap 1000 USDC => 1000 * 10**6)
    uint256 public bankCap;

    // Slippage control: basis points (bps). e.g. 100 = 1.00%
    uint256 public slippageBps = 100; // default 1%

    // total USDC held/credited in the bank (sum of balances mapping)
    uint256 public totalUSDCCredit;

    // balances denominated in USDC smallest units
    mapping(address => uint256) public balancesUSDC;

    // events
    event Deposit(address indexed user, address indexed fromToken, uint256 fromAmount, uint256 usdcReceived);
    event Withdraw(address indexed user, uint256 usdcAmount);
    event BankCapUpdated(uint256 newCap);
    event RouterUpdated(address newRouter);
    event USDCUpdated(address newUSDC, uint8 newDecimals);
    event SlippageUpdated(uint256 newBps);
    event RescueToken(address token, address to, uint256 amount);

    constructor(
        address _router,
        address _usdc,
        uint8 _usdcDecimals,
        uint256 _bankCap
    ) Ownable(msg.sender){
        require(_router != address(0), "Router 0");
        require(_usdc != address(0), "USDC 0");
        router = IUniswapV2Router02(_router);
        usdc = IERC20Metadata(_usdc);
        usdcDecimals = _usdcDecimals;
        bankCap = _bankCap;
    }

    // -------------------------
    // Deposit functions
    // -------------------------

    // Deposit ETH: intercambia ETH -> USDC y acredita el balance del usuario en USDC
    function depositETH() external payable nonReentrant {
    require(msg.value > 0, "Zero ETH");

    // Obtener direccion de WETH del router de Uniswap
    address weth = router.WETH();

    // Ruta del swap: ETH -> USDC (internamente ETH se convierte a WETH)
    address[] memory path = new address[](2);
    path[0] = weth;
    path[1] = address(usdc);

    // Estimamos la cantidad de USDC que recibiríamos
    uint[] memory amountsOut = router.getAmountsOut(msg.value, path);
    uint256 estimatedUsdc = amountsOut[amountsOut.length - 1];

    // Verificamos que no se exceda el límite del banco antes del swap
    require(totalUSDCCredit + estimatedUsdc <= bankCap, "Bank cap exceeded");

    // Aplicamos protección por slippage (por defecto 1%)
    uint256 minOut = _applySlippageDown(estimatedUsdc);

    uint256 deadline = block.timestamp + 600; // 10 minutos

    // Ejecutamos el swap ETH -> USDC
    uint[] memory amounts = router.swapExactETHForTokens{value: msg.value}(
        minOut,      // cantidad mínima de USDC a recibir
        path,        // ruta del swap
        address(this), // destinatario
        deadline
    );

    uint256 receivedUSDC = amounts[amounts.length - 1];

    // Actualizamos los balances
    balancesUSDC[msg.sender] += receivedUSDC;
    totalUSDCCredit += receivedUSDC;

    emit Deposit(msg.sender, address(0), msg.value, receivedUSDC);
}


    // Depositar USDC directamente
    function depositUSDC(uint256 amount) external nonReentrant {
        require(amount > 0, "Zero amount");

        // chequear bank cap
        require(totalUSDCCredit + amount <= bankCap, "Bank cap exceeded");

        // transferir USDC desde un usuario al contrato
        IERC20Metadata(address(usdc)).safeTransferFrom(msg.sender, address(this), amount);

        balancesUSDC[msg.sender] += amount;
        totalUSDCCredit += amount;

        emit Deposit(msg.sender, address(usdc), amount, amount);
    }

    // Depositar algun ERC20 token que tiene directamrnte un par token->USDC en UniswapV2 (path [token, USDC])
    function depositToken(address token, uint256 amountIn) external nonReentrant {
        require(token != address(0), "Token 0");
        require(amountIn > 0, "Zero amount");

        IERC20Metadata tokenContract = IERC20Metadata(token);

        // Transferir token de user al contrato
        tokenContract.safeTransferFrom(msg.sender, address(this), amountIn);

        if (token == address(usdc)) {
            // simple path si el user uso una direccion USDC (deberia usar depositUSDC pero permitir esto)
            require(totalUSDCCredit + amountIn <= bankCap, "Bank cap exceeded");
            balancesUSDC[msg.sender] += amountIn;
            totalUSDCCredit += amountIn;
            emit Deposit(msg.sender, token, amountIn, amountIn);
            return;
        }

        // armar path directo [token, USDC]
        address[] memory path= new address[](2) ;
        path[0] = token;
        path[1] = address(usdc);

        // Usar router.getAmountsOut para estimar amountOut (revierte esto si no hay path)
        uint256 estimatedUsdc;
        try router.getAmountsOut(amountIn, path) returns (uint[] memory amountsOut) {
            estimatedUsdc = amountsOut[amountsOut.length - 1];
        } catch {
            // no path or router reverted
            revert("No direct UniswapV2 path token->USDC");
        }

        // Check bank cap ANTES del swap
        require(totalUSDCCredit + estimatedUsdc <= bankCap, "Bank cap exceeded");

        // Approve router for amountIn (safe pattern: set to 0 then set)
        _safeApprove(tokenContract, address(router), amountIn);

        uint256 minOut = _applySlippageDown(estimatedUsdc);
        uint256 deadline = block.timestamp + 600; // 10 minutes

        // Perform swap: use swapExactTokensForTokens to be able to set amountOutMin
        uint[] memory amounts = router.swapExactTokensForTokens(
            amountIn,
            minOut,
            path,
            address(this),
            deadline
        );

        uint256 receivedUSDC = amounts[amounts.length - 1];

        // update mapping & total
        balancesUSDC[msg.sender] += receivedUSDC;
        totalUSDCCredit += receivedUSDC;

        emit Deposit(msg.sender, token, amountIn, receivedUSDC);
    }

    // -------------------------
    // Withdraw
    // -------------------------

    // Withdraw USDC from user's balance
    function withdrawUSDC(uint256 amount) external nonReentrant {
        require(amount > 0, "Zero amount");
        require(balancesUSDC[msg.sender] >= amount, "Insufficient balance");

        balancesUSDC[msg.sender] -= amount;
        totalUSDCCredit -= amount;

        IERC20Metadata(address(usdc)).safeTransfer(msg.sender, amount);

        emit Withdraw(msg.sender, amount);
    }

    // -------------------------
    // Admin functions
    // -------------------------
    function setBankCap(uint256 newCap) external onlyOwner {
        bankCap = newCap;
        emit BankCapUpdated(newCap);
    }

    function setRouter(address newRouter) external onlyOwner {
        require(newRouter != address(0), "Router 0");
        router = IUniswapV2Router02(newRouter);
        emit RouterUpdated(newRouter);
    }

    function setUSDC(address newUsdc, uint8 newDecimals) external onlyOwner {
        require(newUsdc != address(0), "USDC 0");
        usdc = IERC20Metadata(newUsdc);
        usdcDecimals = newDecimals;
        emit USDCUpdated(newUsdc, newDecimals);
    }

    function setSlippageBps(uint256 newBps) external onlyOwner {
        require(newBps <= 1000, "Slippage too high"); // 10% max guard
        slippageBps = newBps;
        emit SlippageUpdated(newBps);
    }

    // Rescue function for tokens accidentally sent to contract (owner only).
    // NOTE: cannot rescue USDC that are credited in the bank without adjusting balances.
    function rescueToken(address token, address to, uint256 amount) external onlyOwner {
        require(to != address(0), "Zero receiver");
        require(amount > 0, "Zero amount");
        // If rescuing USDC, ensure we don't steal user's balances (we only allow rescue of excess USDC)
        if (token == address(usdc)) {
            uint256 currentUsdcBalance = IERC20Metadata(token).balanceOf(address(this));
            // permitted rescue = balance - totalUSDCCredit
            require(currentUsdcBalance > totalUSDCCredit, "No excess USDC");
            uint256 excess = currentUsdcBalance - totalUSDCCredit;
            require(amount <= excess, "Amount > excess");
        }
        IERC20Metadata(token).safeTransfer(to, amount);
        emit RescueToken(token, to, amount);
    }

    // Allow owner to withdraw ETH (accidental) - only ETH not used in swaps (although we try not to keep ETH)
    function rescueETH(address payable to, uint256 amount) external onlyOwner {
        require(to != address(0), "Zero to");
        require(amount <= address(this).balance, "Amount>balance");
        to.transfer(amount);
    }

    // -------------------------
    // View helpers
    // -------------------------

    // returns balance of caller in USDC units
    function myUSDCBalance() external view returns (uint256) {
        return balancesUSDC[msg.sender];
    }

    // Estimate how much USDC would be received swapping 'amountIn' of token -> USDC (direct pair required)
    function estimateTokenToUSDC(address token, uint256 amountIn) external view returns (uint256) {
        if (token == address(usdc)) {
            return amountIn;
        }
        address[] memory path= new address[](2);
        if (token == address(0)) { // token=0 implies ETH input
            address weth = router.WETH();
            path[0] = weth;
            path[1] = address(usdc);
        } else {
            path[0] = token;
            path[1] = address(usdc);
        }
        uint[] memory amountsOut = router.getAmountsOut(amountIn, path);
        return amountsOut[amountsOut.length - 1];
    }

    // -------------------------
    // Internal helpers
    // -------------------------

    // Apply slippage downwards: returns floor(amount * (10000 - slippageBps) / 10000)
    function _applySlippageDown(uint256 amount) internal view returns (uint256) {
        if (slippageBps == 0) return amount;
        uint256 numerator = amount * (10000 - slippageBps);
        return numerator / 10000;
    }

    // Approve safely (reset to 0 then approve)
    function _safeApprove(IERC20Metadata token, address spender, uint256 amount) internal {
        uint256 currentAllowance = token.allowance(address(this), spender);
        if (currentAllowance < amount) {
            if (currentAllowance > 0) {
               token.approve(spender,0);
            }
            token.approve(spender, amount);
        }
    }

    // small helper to convert int to uint (used above)
    function intToUint(uint256 a) internal pure returns (uint256) {
        return a;
    }

    // receive fallback to allow swaps that send ETH to contract (but depositETH uses payable)
    receive() external payable {}
}
