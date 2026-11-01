The codebase implements a complex, multi-threaded, and state-driven social deduction game (Love Letter) written in GDScript, leveraging Godot's scene and signal architecture. The design is
 modular, relying on dedicated classes for core concepts like Players, Cards, and the Game Manager itself.

 ### Architectural Overview

 The system follows a Central Manager pattern where the primary script managing the game state (Main.gd) orchestrates interactions between specialized components.

 1. Main.gd (Game Manager/State Machine):
     - Role: Singleton equivalent for game flow control. It determines the current game state, checks for round victories, manages turn progression, and initiates core game sequence phases
       (Dealing, Player Action, Effect Resolution).
     - Mechanism: It maintains lists of active $Player objects and coordinates their actions. It acts as the event dispatcher that routes game logic after a core action (e.g., when a Card
       is played, it triggers specific effect logic in resolve_effect()).
     - Dependencies: Highly dependent on the APIs provided by Player, Card, and Deck.
 2. Player.gd (Entity/Logic Component):
     - Role: Represents an individual player, managing their state, hand, score, and making decisions (especially for AI).
     - Mechanism: Implements robust state machines (e.g., State.IDLE, State.INPUT_OTHER_P). It contains core gameplay logic for AI decision-making (select_move, eval_moves) and tracks game
       knowledge via a dedicated Memory System (_memory array).
     - Communication: Uses signals (card_played, target_player_selected, move_chosen) to signal actions to the Main manager, upholding loose coupling.
 3. Card.gd (View/Data Carrier):
     - Role: Represents a single card instance. It primarily binds visual assets (Sprite) to typed data (type and faceup state).
     - Mechanism: It is kept intentionally thin, primarily being a visual representation governed by state inputs from its parent logic (e.g., the Player node). It signals its own actions
       when played.
 4. Deck.gd (Data Repository/Rules Engine):
     - Role: Manages the entire deck, including drawing, discarding, and knowing the structural rules of the game (e.g., the counts of each card type).
     - Mechanism: Uses internal arrays (_cards, _widow_cards, _left) to track available cards and enforce card supply limits. It defines the critical game enum: CardType.

 ────────────────────────────────────────────────────────────────────────────────

 ### Design Guidelines for Reusage

 To successfully reuse this project structure in a similar project, adhere to the following principles:

 1. State Management (The Single Source of Truth):
     - Rule: Never allow components to unilaterally change critical game states. All state changes must flow through the primary manager (Main.gd).
     - Guideline: If adding a new mechanic (e.g., a new card card effect), modify the central resolve_effect() function, rather than adding direct logic to the Card.gd script itself.
 2. Communication (Signals over Direct Calls):
     - Rule: Components must communicate using Godot Signals exclusively for actions that change the game state.
     - Benefit: This vastly improves testability and modularity. For example, the Player component should emit card_played(card) when a user taps a card, but the Main game manager should be
       the component listening for this signal and executing the follow-up logic.
 3. AI and Scoring Logic:
     - Rule: Separate complexity into dedicated, pure logic modules.
     - Guideline: The Player.gd script heavily mixes AI logic (e.g., eval_moves calculating scores based on comparison rules). If the game expands, extract the scoring calculation logic
       into a helper object or class, keeping Player.gd focused on Player behavior and Node management.
 4. Data Definition (Enums and Typed Constants):
     - Rule: All critical game identifiers (Card Types, Player States) must be defined immutably at the highest logical level (e.g., in Deck.gd's enum).
     - Guideline: Use class_name heavily. This ensures type safety and makes referencing game constants clean throughout the codebase.
 5. Memory/Deduction System:
     - Rule: Maintain a single, reliable source of truth for player knowledge.
     - Guideline: The _memory array in Player.gd is key. When memory updates are required across the board (e.g., after a "King" swap), the Main script must iterate and explicitly call
       update_memory() on all affected other players.

